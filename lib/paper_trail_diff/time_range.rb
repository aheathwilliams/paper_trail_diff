# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Validates and applies a finite wall-clock range without loading model state.
  class TimeRange
    attr_reader :begin_time #: Time
    attr_reader :end_time #: Time

    #: (untyped) -> void
    def initialize(value)
      unless value.is_a?(Range) && value.begin && value.end
        raise InvalidTimeRangeError, '`within` must be a finite Range'
      end

      @begin_time = coerce_time(value.begin, boundary: :begin)
      @end_time = coerce_time(value.end, boundary: :end)
      @exclude_end = value.exclude_end?
      validate_order!
      freeze
    end

    #: () -> bool
    def exclude_end?
      @exclude_end
    end

    #: (untyped) -> bool
    def include?(value)
      timestamp = coerce_time(value, boundary: :timestamp)
      return false if timestamp < begin_time

      exclude_end? ? timestamp < end_time : timestamp <= end_time
    end

    #: (untyped) -> untyped
    def scope(relation)
      relation.where(created_at: query_range)
    end

    #: (untyped) -> untyped
    def trailing_scope(relation)
      column = relation.klass.arel_table[:created_at]
      predicate = exclude_end? ? column.gteq(end_time) : column.gt(end_time)
      relation.where(predicate)
    end

    private

    # @rbs @exclude_end: bool

    #: () -> Range[Time]
    def query_range
      exclude_end? ? (begin_time...end_time) : (begin_time..end_time)
    end

    #: (untyped, boundary: Symbol) -> Time
    def coerce_time(value, boundary:)
      unless value.respond_to?(:to_time)
        raise InvalidTimeRangeError, "`within` #{boundary} must be time-like"
      end

      time_value(value).getutc.freeze
    rescue ArgumentError, NoMethodError, TypeError => e
      raise InvalidTimeRangeError,
            "`within` #{boundary} must be time-like",
            cause: e
    end

    #: (untyped) -> Time
    def time_value(value)
      return value if value.is_a?(Time)

      utc = value.utc if value.respond_to?(:utc)
      utc.is_a?(Time) ? utc : value.to_time
    end

    #: () -> void
    def validate_order!
      return unless begin_time > end_time

      raise InvalidTimeRangeError, '`within` beginning must not follow its end'
    end
  end
end
