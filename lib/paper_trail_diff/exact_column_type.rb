# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The kind of value a column holds when its database compares it exactly
  # as Ruby compares the attribute's values, which is what lets ScopeCondition
  # and ScopeRanking decide a scope in Ruby. Each adapter lists the SQL types
  # it compares that way, so a type it does not list, such as PostgreSQL's
  # character(n) or citext, and an adapter it does not know, fall back to the
  # caller's slower path rather than being trusted.
  module ExactColumnType
    # Kinds by SQL type, without its size, precision or scale. Integers,
    # booleans and dates compare alike everywhere listed. Text compares
    # exactly only where the database compares strings byte by byte by
    # default: MySQL and SQL Server ignore case and trailing spaces, and
    # PostgreSQL pads character(n). A datetime is listed where it keeps the
    # value Active Record writes; SQL Server's datetime rounds it to 1/300 s.
    # A time of day is not listed: in memory it keeps the date it was given,
    # which the database drops.
    MYSQL_TYPES = {
      'tinyint(1)' => :boolean, 'tinyint' => :integer, 'smallint' => :integer,
      'mediumint' => :integer, 'int' => :integer, 'bigint' => :integer,
      'tinyint unsigned' => :integer, 'smallint unsigned' => :integer,
      'mediumint unsigned' => :integer, 'int unsigned' => :integer, 'bigint unsigned' => :integer,
      'date' => :date, 'datetime' => :datetime, 'timestamp' => :datetime
    }.freeze
    SQL_TYPES = {
      'postgresql' => {
        'smallint' => :integer, 'integer' => :integer, 'bigint' => :integer,
        'boolean' => :boolean, 'character varying' => :text, 'text' => :text, 'date' => :date,
        'timestamp without time zone' => :datetime, 'timestamp with time zone' => :datetime
      }.freeze,
      'sqlite3' => {
        'integer' => :integer, 'int' => :integer, 'smallint' => :integer, 'bigint' => :integer,
        'boolean' => :boolean, 'varchar' => :text, 'text' => :text, 'date' => :date,
        'datetime' => :datetime
      }.freeze,
      'mysql2' => MYSQL_TYPES,
      'trilogy' => MYSQL_TYPES,
      'sqlserver' => {
        'tinyint' => :integer, 'smallint' => :integer, 'int' => :integer, 'bigint' => :integer,
        'bit' => :boolean, 'date' => :date, 'datetime2' => :datetime
      }.freeze
    }.freeze
    # The Active Model type that casts each kind's values in Ruby, named so
    # that loading needs no Active Model. An attribute type of another class,
    # such as one that serializes or encrypts the column, reads no kind.
    RUBY_TYPES = { integer: 'ActiveModel::Type::Integer', boolean: 'ActiveModel::Type::Boolean',
                   text: 'ActiveModel::Type::ImmutableString', date: 'ActiveModel::Type::Date',
                   datetime: 'ActiveModel::Type::DateTime' }.freeze
    ENUM_TYPE = 'ActiveRecord::Enum::EnumType'
    # Rails wraps a time-zone-aware attribute's type, by default every
    # datetime's, in this delegator; the time it stores is the wrapped type's.
    TIME_ZONE_TYPE = 'ActiveRecord::AttributeMethods::TimeZoneConversion::TimeZoneConverter'
    private_constant :MYSQL_TYPES, :RUBY_TYPES, :ENUM_TYPE, :TIME_ZONE_TYPE

    # nil for anything but a column of the model's own table whose SQL type
    # its adapter lists and whose attribute type reads that kind. Text with
    # its own collation compares as that collation says, so it reads none.
    #: (untyped, String?) -> Symbol?
    def self.kind(model_class, name)
      column = model_class.columns_hash[name]
      return unless column

      kind = sql_kind(model_class.connection_db_config.adapter, column.sql_type)
      return unless kind && (kind != :text || column.collation.nil?)

      kinds = stored_type(model_class.type_for_attribute(name)).class.ancestors.map(&:name)
      kind if kinds.include?(RUBY_TYPES.fetch(kind))
    end

    # The type of the value a column stores, under an enum or time zone
    # wrapper. An enum stores what its subtype casts.
    #: (untyped) -> untyped
    def self.stored_type(type)
      type = type.subtype if ENUM_TYPE.eql?(type.class.name)
      TIME_ZONE_TYPE.eql?(type.class.name) ? type.__getobj__ : type
    end

    # A type is listed with its size where that changes its kind, as MySQL's
    # tinyint(1) holds a boolean.
    #: (String, String) -> Symbol?
    def self.sql_kind(adapter, sql_type)
      types = SQL_TYPES[adapter]
      return unless types

      sql_type = sql_type.downcase
      types[sql_type] || types[sql_type.gsub(/\s*\([^)]*\)/, '')]
    end
    private_class_method :sql_kind
  end
end
