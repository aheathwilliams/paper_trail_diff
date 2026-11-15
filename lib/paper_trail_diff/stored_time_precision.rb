# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Matches time values to the precision PaperTrail actually stored.
  #
  # PaperTrail's JSON serializer, and a `json` or `jsonb` object column, write
  # times through ActiveSupport's JSON encoder, which keeps only
  # `ActiveSupport::JSON::Encoding.time_precision` fractional digits
  # (milliseconds by default). The live row keeps the database's precision, so
  # comparing the two would report every timestamp as changed even though
  # nothing was edited. Truncating every side to the stored precision is
  # idempotent, so values that came from history are unaffected and only the
  # digits history could never have held are dropped.
  module StoredTimePrecision
    NANOSECOND_DIGITS = 9
    JSON_COLUMN_TYPES = %i[json jsonb].freeze
    private_constant :NANOSECOND_DIGITS, :JSON_COLUMN_TYPES

    # Fractional digits a model's history keeps for times, or nil when the
    # history is stored losslessly.
    #: (untyped) -> Integer?
    def self.digits(model_class)
      return unless Support.versioned?(model_class)
      return unless json_history?(model_class.paper_trail.version_class)

      json_time_precision
    end

    #: (Hash[untyped, untyped], Integer?) -> Hash[untyped, untyped]
    def self.apply(attributes, digits)
      return attributes unless digits

      attributes.transform_values { |value| truncate(value, digits) }
    end

    # From nine digits on, the step is one nanosecond or a fraction of one, so
    # nothing is cut.
    #: (untyped, Integer) -> untyped
    def self.truncate(value, digits)
      return value unless value.is_a?(Time)

      # ActiveSupport's Time#change, which also serves TimeWithZone.
      time = value #: untyped
      remainder = time.nsec % (10**(NANOSECOND_DIGITS - digits))
      remainder.zero? ? time : time.change(nsec: time.nsec - remainder)
    end

    #: (untyped) -> bool
    def self.json_history?(version_class)
      %w[object object_changes].any? { |name| json_column?(version_class, name) } ||
        json_serializer?
    end
    private_class_method :json_history?

    # Whether the version table keeps this column as `json` or `jsonb`, which
    # PaperTrail writes without its serializer. A version that is not an
    # Active Record model has no table.
    #: (untyped, String) -> bool
    def self.json_column?(version_class, name)
      version_class.respond_to?(:columns_hash) &&
        JSON_COLUMN_TYPES.include?(version_class.columns_hash[name]&.type)
    end

    # mutant:disable - Every mutation that survives here reads the same
    # constant another way: from this module rather than Object, or with `::`.
    #: () -> Integer
    def self.json_time_precision
      active_support = Object.const_get(:ActiveSupport) #: untyped
      active_support.const_get(:JSON).const_get(:Encoding).time_precision
    end
    private_class_method :json_time_precision

    # Whether PaperTrail writes history with its JSON serializer.
    # mutant:disable - As for json_time_precision.
    #: () -> bool
    def self.json_serializer?
      paper_trail = Object.const_get(:PaperTrail) #: untyped
      paper_trail.serializer.equal?(paper_trail.const_get(:Serializers).const_get(:JSON))
    end
  end
end
