# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reads each value as the database stores it.
  #
  # PaperTrail writes a version from the instance in memory, which can hold a
  # value more exactly than its column does: a record saved twice through one
  # instance records the value as Ruby held it, and every later version as the
  # row gave it back. The two would compare as an edit nobody made. Each side
  # is brought to the form the column keeps, which leaves a value read from
  # the row as it is:
  #
  # - a time in a column without a declared precision, which Active Record
  #   writes with six fractional digits, and SQL Server's `datetime` rounds
  #   to 1/300 s;
  # - a fixed-width string, which PostgreSQL and SQL Server pad with spaces
  #   and MySQL reads back without trailing spaces;
  # - MySQL's single-precision `float`, which reads back with six significant
  #   digits;
  # - a decimal on SQLite, which stores it as a double.
  #
  # Other columns are read as they are; docs/reference.md lists the limit.
  module StoredForm
    MICROSECOND_DIGITS = 6
    SQL_SERVER_DATETIME_STEPS = 300
    FIXED_WIDTH = /\A(?:n?char|character)\(\d+\)\z/i
    INT64 = 2**63
    private_constant :MICROSECOND_DIGITS, :SQL_SERVER_DATETIME_STEPS, :FIXED_WIDTH, :INT64

    @forms = {} #: Hash[untyped, Hash[String, ^(untyped) -> untyped]]

    #: (untyped, Hash[untyped, untyped]) -> Hash[untyped, untyped]
    def self.apply(model_class, attributes)
      forms = forms(model_class)
      return attributes if forms.empty?

      attributes.to_h do |name, value|
        form = forms[name.to_s]
        [name, form && !value.nil? ? form.call(value) : value]
      end
    end

    # The form each column of the model's table needs, by name.
    #: (untyped) -> Hash[String, ^(untyped) -> untyped]
    def self.forms(model_class)
      known = @forms #: Hash[untyped, Hash[String, ^(untyped) -> untyped]]
      known.fetch(model_class) do
        adapter = model_class.connection_db_config.adapter.to_s
        known[model_class] = model_class.columns.each_with_object({}) do |column, forms|
          form = form(adapter, column, model_class.type_for_attribute(column.name))
          forms[column.name] = form if form
        end.freeze
      end
    end
    private_class_method :forms

    #: (String, untyped, untyped) -> (^(untyped) -> untyped)?
    def self.form(adapter, column, type)
      case column.type
      when :datetime, :timestamp, :time then time_form(adapter, column, type)
      when :float then float_form(adapter, column)
      when :decimal then decimal_form(adapter, type)
      else fixed_width_form(adapter, column)
      end
    end
    private_class_method :form

    # Active Record truncates a time to a declared precision itself.
    #: (String, untyped, untyped) -> (^(untyped) -> untyped)?
    def self.time_form(adapter, column, type)
      return if type.respond_to?(:precision) && type.precision
      return method(:sql_server_datetime) if adapter == 'sqlserver' && column.sql_type.casecmp?('datetime')

      ->(value) { StoredTimePrecision.truncate(value, MICROSECOND_DIGITS) } unless adapter == 'sqlserver'
    end
    private_class_method :time_form

    # SQL Server's `datetime` keeps steps of 1/300 s, read back to the
    # millisecond, and rounds to the nearest.
    #: (untyped) -> untyped
    def self.sql_server_datetime(value)
      return value unless value.is_a?(Time)

      time = value #: untyped
      steps = (time.subsec * SQL_SERVER_DATETIME_STEPS).round
      milliseconds = Rational((steps * 1000r / SQL_SERVER_DATETIME_STEPS).round, 1000)
      time.change(nsec: 0) + milliseconds
    end
    private_class_method :sql_server_datetime

    # MySQL's `float` is single precision, read back with six digits.
    #: (String, untyped) -> (^(untyped) -> untyped)?
    def self.float_form(adapter, column)
      return unless %w[mysql2 trilogy].include?(adapter) && column.sql_type.casecmp?('float')

      lambda do |value|
        value.is_a?(Float) && value.finite? ? Float(format('%.6g', [value].pack('f').unpack1('f'))) : value
      end
    end
    private_class_method :float_form

    # SQLite keeps a decimal as a double, or as an integer when it is a whole
    # number that fits one, and Active Record casts what it reads back.
    #: (String, untyped) -> (^(untyped) -> untyped)?
    def self.decimal_form(adapter, type)
      return unless adapter == 'sqlite3'

      lambda do |value|
        return value unless value.is_a?(Numeric)

        stored = value.to_f
        stored = stored.to_i if stored.finite? && stored == stored.truncate && stored.abs < INT64
        type.cast(stored)
      end
    end
    private_class_method :decimal_form

    #: (String, untyped) -> (^(untyped) -> untyped)?
    def self.fixed_width_form(adapter, column)
      return unless FIXED_WIDTH.match?(column.sql_type) && column.limit

      if %w[mysql2 trilogy].include?(adapter)
        ->(value) { value.is_a?(String) ? value.sub(/ +\z/, '') : value }
      elsif %w[postgresql sqlserver].include?(adapter)
        width = column.limit
        ->(value) { value.is_a?(String) ? value.ljust(width) : value }
      end
    end
    private_class_method :fixed_width_form
  end
end
