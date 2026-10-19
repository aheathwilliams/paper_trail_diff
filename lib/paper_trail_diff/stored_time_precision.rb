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

    module_function

    # Fractional digits a model's history keeps for times, or nil when the
    # history is stored losslessly.
    #: (untyped) -> Integer?
    def digits(model_class)
      return unless Support.versioned?(model_class)
      return unless json_history?(model_class.paper_trail.version_class)

      active_support = Object.const_get(:ActiveSupport) #: untyped
      active_support.const_get(:JSON).const_get(:Encoding).time_precision
    end

    #: (Hash[untyped, untyped], Integer?) -> Hash[untyped, untyped]
    def apply(attributes, digits)
      return attributes unless digits

      attributes.transform_values { |value| truncate(value, digits) }
    end

    #: (untyped, Integer) -> untyped
    def truncate(value, digits)
      return value unless value.is_a?(Time) && digits < NANOSECOND_DIGITS

      # ActiveSupport's Time#change, which also serves TimeWithZone.
      time = value #: untyped
      step = 10**(NANOSECOND_DIGITS - [digits, 0].max) #: Integer
      remainder = time.nsec % step
      remainder.zero? ? time : time.change(nsec: time.nsec - remainder)
    end

    #: (untyped) -> bool
    def json_history?(version_class)
      columns = version_class.columns_hash
      json_column = %w[object object_changes].any? do |name|
        JSON_COLUMN_TYPES.include?(columns[name]&.type)
      end
      json_column || json_serializer?
    end
    private_class_method :json_history?

    #: () -> bool
    def json_serializer?
      paper_trail = Object.const_get(:PaperTrail) #: untyped
      paper_trail.serializer.equal?(paper_trail.const_get(:Serializers).const_get(:JSON))
    end
    private_class_method :json_serializer?
  end
end
