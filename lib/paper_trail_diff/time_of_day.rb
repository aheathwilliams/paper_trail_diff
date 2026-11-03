# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reads every value of a `time` column on 2000-01-01, in its own zone.
  #
  # A time column keeps only the time, but Active Record before 8.1 gives a
  # zone-aware one a date two ways: assigned, it falls on 2000-01-01 in the
  # time zone; read from the database, on 2000-01-01 in UTC. A version rebuilt
  # by assignment and the row read for the same time could then hold it a day
  # apart, east of UTC in the morning and west of it in the evening, and
  # compare as a change. Every side is read the way Active Record 8.1 reads
  # both, which leaves a value already on that date as it is.
  module TimeOfDay
    @columns = {} #: Hash[untyped, Array[String]]

    #: (untyped, Hash[untyped, untyped]) -> Hash[untyped, untyped]
    def self.apply(model_class, attributes)
      columns = columns(model_class)
      return attributes if columns.empty?

      attributes.to_h do |name, value|
        [name, columns.include?(name) && value ? value.change(**Support::TIME_OF_DAY_DATE) : value]
      end
    end

    # The model's `time` columns, which a model keeps as it was defined.
    #: (untyped) -> Array[String]
    def self.columns(model_class)
      known = @columns #: Hash[untyped, Array[String]]
      known.fetch(model_class) do
        known[model_class] = model_class.attribute_types.filter_map do |name, type|
          name if type.type == :time
        end
      end
    end
    private_class_method :columns
  end
end
