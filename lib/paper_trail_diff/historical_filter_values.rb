# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The values an attribute hash given to `historical_filter:` expects, each
  # read as `where` reads it and as history can hold it.
  class HistoricalFilterValues
    # Values `where` reads as several.
    SEVERAL = [Array, Range, Set].freeze
    # The expected value of an attribute `where` would compare with NULL,
    # which no stored value equals.
    NOTHING = Object.new.freeze
    private_constant :SEVERAL, :NOTHING

    #: (untyped) -> void
    def initialize(model)
      @model = model
    end

    #: (Hash[untyped, untyped]) -> Hash[String, untyped]
    def call(predicate)
      named_attributes(predicate).to_h { |name, value| [name, expected(name, value)] }
    end

    # A value cast, then read as history can hold it (see StoredValues), so
    # that one filter value means the same in a version and in the live row:
    # JSON history keeps a time to the millisecond, and a column can keep a
    # value less exactly than Ruby does. A value the attribute cannot take,
    # such as a Hash for a time, is refused with the gem's own error.
    #: (String, untyped) -> untyped
    def stored(name, value)
      StoredValues.apply(@model, { name => cast(name, value) }).fetch(name)
    rescue ArgumentError, TypeError,
           Support.constant('ActiveRecord::SerializationTypeMismatch') => e
      raise ConfigurationError,
            "historical_filter: #{name} cannot take #{value.class}: #{e.message}"
    end

    private

    # @rbs @model: untyped

    # The attribute hash by name, each named once and on the model.
    #: (Hash[untyped, untyped]) -> Hash[String, untyped]
    def named_attributes(predicate)
      attributes = predicate.transform_keys(&:to_s)
      if attributes.length < predicate.length
        raise ConfigurationError,
              'historical_filter: names an attribute twice, as a string and a symbol'
      end

      # An attribute without a column is not stored, and `where` cannot
      # name it either (see StoredValues).
      unknown = attributes.keys - @model.column_names
      return attributes if unknown.empty?

      raise ConfigurationError, "unknown historical attributes: #{unknown.join(', ')}"
    end

    # `where` reads a list or a range as any of its values, which an
    # equality with one cast value cannot mean, so it is refused unless the
    # attribute itself holds one, as a serialized or an array column does.
    #: (String, untyped) -> untyped
    def expected(name, value)
      cast = stored(name, value)
      if SEVERAL.any? { |kind| value.is_a?(kind) } && !cast.is_a?(value.class)
        raise ConfigurationError,
              "historical_filter: #{name} takes one value, not #{value.class.name.downcase}; " \
              'use a callable to match any of several'
      end

      unbound?(name, value) ? NOTHING : cast
    end

    # `where` writes IS NULL for nil, but `= NULL`, which matches no row, for
    # a value its type cannot write, such as '' or 'abc' for an integer, and
    # a constant false condition for one out of the column's range.
    #: (String, untyped) -> bool
    def unbound?(name, value)
      return false if value.nil?

      # The attribute's name is not read.
      bound = Support.constant('ActiveRecord::Relation::QueryAttribute')
                     .new(nil, value, @model.type_for_attribute(name)) #: untyped
      bound.unboundable? || bound.value_for_database.nil?
    end

    # Expected and recorded values compare as the attribute casts them, as
    # `where` reads its values: an enum's symbol names its stored value, and a
    # `json` or `jsonb` version column, which PaperTrail does not cast, holds
    # dates and times as strings. Casting also copies a mutable value, so the
    # filter keeps its own. A date or text for a datetime column is read as
    # the database reads it (see DatabaseTime).
    #: (String, untyped) -> untyped
    def cast(name, value)
      type = @model.type_for_attribute(name)
      type.cast(type.type == :datetime ? DatabaseTime.cast(value) : value)
    end
  end
end
