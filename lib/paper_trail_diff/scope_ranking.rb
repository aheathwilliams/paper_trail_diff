# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The order, offset and limit by which a scope picks its members from the
  # records that meet its conditions, as the database would rank them. It is
  # read only when the order is total and every key compares in Ruby as SQL
  # compares it; otherwise build returns nil and the caller keeps its slower
  # path.
  class ScopeRanking
    DIRECTIONS = { 'Arel::Nodes::Ascending' => false, 'Arel::Nodes::Descending' => true }.freeze
    ATTRIBUTE = 'Arel::Attributes::Attribute'
    ENUM_TYPE = 'ActiveRecord::Enum::EnumType'
    # Rails wraps a time-zone-aware attribute's type, by default every
    # datetime's, in this delegator; the time it stores is the wrapped type's.
    TIME_ZONE_TYPE = 'ActiveRecord::AttributeMethods::TimeZoneConversion::TimeZoneConverter'
    # Integers, booleans and dates sort alike everywhere. Strings follow a
    # collation, so they are not read.
    ORDER_TYPES = %w[ActiveModel::Type::Integer ActiveModel::Type::Boolean
                     ActiveModel::Type::Date].freeze
    # Times sort alike only at the precision both the column and history
    # keep. A time of day is not read: in memory it keeps the date it was
    # given, which the database drops.
    DATETIME_TYPE = 'ActiveModel::Type::DateTime'
    # Where each adapter sorts NULL in an ascending order by default; a
    # descending order reverses it. Another adapter's ranking is not read.
    NULLS_LAST = { 'postgresql' => true, 'sqlite3' => false, 'mysql2' => false,
                   'trilogy' => false, 'sqlserver' => false }.freeze
    # Places in a sort key, of which only the order counts: a value between a
    # NULL sorted first and one sorted last, and false before true. Every
    # value is a number, so that a descending key can negate it.
    NULL_PLACE = { false => -1, true => 1 }.freeze
    VALUE_PLACE = 0
    BOOLEAN_VALUE = { false => 0, true => 1 }.freeze

    # Whether the relation picks members by rank rather than by condition
    # alone. A has_one takes the first record its order names.
    #: (untyped, untyped) -> bool
    def self.ranks?(relation, reflection)
      !relation.limit_value.nil? || !relation.offset_value.nil? ||
        (reflection.has_one? && !relation.order_values.empty?)
    end

    # A has_many, through or not, or a direct has_one is ranked per owner as
    # its own query ranks it. A has_many through ranks the rows its join
    # yields, a record reached twice counting twice, by its own order first.
    # Returns nil when the ranking cannot be read exactly.
    #: (untyped, untyped, untyped) -> ScopeRanking?
    def self.build(relation, reflection, model_class)
      return unless own?(reflection) && plain_offset?(relation)

      keys = keys(relation.order_values, model_class)
      return unless keys

      nulls_last = NULLS_LAST[model_class.connection_db_config.adapter]
      return if nulls_last.nil?

      new(model_class, keys, nulls_last, relation.limit_value, relation.offset_value)
    end

    #: (untyped) -> bool
    def self.own?(reflection)
      reflection.macro == :has_many || (reflection.has_one? && !reflection.through_reflection?)
    end
    private_class_method :own?

    # Active Record casts a limit to an integer but keeps an offset as given,
    # which may be a String or SQL.
    #: (untyped) -> bool
    def self.plain_offset?(relation)
      !relation.offset_value.is_a?(String)
    end
    private_class_method :plain_offset?

    # The order's keys up to the primary key, which makes it total. Keys
    # after it never decide anything.
    #: (Array[untyped], untyped) -> Array[[String, bool]]?
    def self.keys(nodes, model_class)
      names = nodes.map { |node| column(node, model_class) }
      total = names.index(model_class.primary_key)
      return unless total

      deciding = nodes.first(total + 1).zip(names)
      return unless deciding.all? { |_node, name| name }

      deciding.map do |node, name|
        column = name #: String
        [column, DIRECTIONS.fetch(node.class.name)]
      end
    end
    private_class_method :keys

    # The record's own column, sorted plainly in one direction.
    #: (untyped, untyped) -> String?
    def self.column(node, model_class)
      return unless DIRECTIONS.key?(node.class.name)

      attribute = node.expr
      return unless ATTRIBUTE.eql?(attribute.class.name)

      table = attribute.relation
      return unless table.name == model_class.table_name && table.table_alias.nil?

      name = attribute.name
      name if orderable?(model_class, name)
    end
    private_class_method :column

    #: (untyped, String) -> bool
    def self.orderable?(model_class, name)
      return false unless model_class.columns_hash.key?(name)

      type = stored_type(model_class.type_for_attribute(name))
      kinds = type.class.ancestors.map(&:name)
      ORDER_TYPES.intersect?(kinds) ||
        (kinds.include?(DATETIME_TYPE) && exact_time?(model_class, type))
    end

    # The value the database sorts by, as the column's type casts it. An enum
    # sorts by the integer it stores; other types are compared cast, since an
    # adapter may serialize a time or date as a wrapper, as SQL Server does.
    #: (untyped, String, untyped) -> untyped
    def self.sort_value(model_class, name, value)
      type = model_class.type_for_attribute(name)
      cast = type.cast(value)
      ENUM_TYPE.eql?(type.class.name) ? type.serialize(cast) : cast
    end

    # The type of the value a column stores, under an enum or time zone wrapper.
    #: (untyped) -> untyped
    def self.stored_type(type)
      type = type.subtype if ENUM_TYPE.eql?(type.class.name)
      TIME_ZONE_TYPE.eql?(type.class.name) ? type.__getobj__ : type
    end
    private_class_method :stored_type

    # Active Record truncates a time to its column's precision before writing
    # it, so history holds the stored value when it keeps that many digits.
    # Times the type stores in UTC sort as the instants they name; local
    # times repeat an hour when clocks go back.
    #: (untyped, untyped) -> bool
    def self.exact_time?(model_class, type)
      precision = type.precision
      digits = StoredTimePrecision.digits(model_class)
      !precision.nil? && (digits.nil? || digits >= precision) && type.default_timezone == :utc
    end
    private_class_method :exact_time?

    #: (untyped, Array[[String, bool]], bool, Integer?, Integer?) -> void
    def initialize(model_class, keys, nulls_last, limit, offset)
      @model_class = model_class
      @keys = keys
      @nulls_last = nulls_last
      @limit = limit
      @offset = offset
      freeze
    end

    # The members among records that met the scope's conditions, in order.
    #: (Array[untyped]) -> Array[untyped]
    def call(records)
      offset = @offset
      limit = @limit
      ranked = records.sort_by { |record| sort_key(record.attributes) }
      ranked = ranked.drop(offset) if offset
      limit ? ranked.first(limit) : ranked
    end

    private

    # @rbs @model_class: untyped
    # @rbs @keys: Array[[String, bool]]
    # @rbs @nulls_last: bool
    # @rbs @limit: Integer?
    # @rbs @offset: Integer?

    # Keys compare in turn, and the primary key always decides. A descending
    # key negates its places, which also moves NULL to the other end, as each
    # adapter does by default.
    #: (Hash[String, untyped]) -> Array[Array[Numeric]]
    def sort_key(attributes)
      @keys.map do |name, descending|
        place = place(ScopeRanking.sort_value(@model_class, name, attributes[name]))
        descending ? place.map(&:-@) : place
      end
    end

    # NULL holds the adapter's place alone, so it never compares as a value.
    # A version saved before its column existed holds NULL there too.
    #: (untyped) -> Array[Numeric]
    def place(value)
      return [NULL_PLACE.fetch(@nulls_last)] if value.nil?

      [VALUE_PLACE, number(value)]
    end

    # A time as its seconds, exactly, and a date as its day number.
    #: (untyped) -> Numeric
    def number(value)
      value = BOOLEAN_VALUE.fetch(value, value)
      value = value.jd if value.respond_to?(:jd)
      value.to_r
    end
  end
end
