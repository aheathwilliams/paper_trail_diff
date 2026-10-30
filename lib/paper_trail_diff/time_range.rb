# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Validates and applies a finite wall-clock range without loading model state.
  #
  # A Date is a whole day and a String a local time, both in Time.zone, as
  # Rails reads them, or in UTC without one: never the server's own zone. An
  # inclusive Date end runs through that day.
  class TimeRange
    attr_reader :begin_time #: Time
    attr_reader :end_time #: Time

    #: (untyped) -> void
    def initialize(value)
      unless value.is_a?(Range) && value.begin && value.end
        raise InvalidTimeRangeError, '`within` must be a finite Range'
      end

      @begin_time = coerce_time(value.begin, boundary: :begin)
      @exclude_end = value.exclude_end? || calendar_date?(value.end)
      @end_time = coerce_time(end_value(value), boundary: :end)
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
      relation.where(after_end(relation.arel_table[:created_at]))
    end

    # Each item's earliest version after the range, keyed by item id. One row
    # per item comes back from a NOT EXISTS rather than a window function, so
    # the query stays portable; a timestamp tie keeps the lower id.
    #: (untyped) -> Hash[String, untyped]
    def first_trailing_versions(relation)
      table = relation.arel_table
      first_after = VersionQuery.no_earlier_version(table) do |earlier|
        after_end(earlier[:created_at])
      end
      versions = VersionQuery.chronological(trailing_scope(relation).where(first_after))
      first = {} #: Hash[String, untyped]
      versions.each { |version| first[version.item_id.to_s] ||= version }
      first
    end

    private

    # @rbs @exclude_end: bool

    #: (untyped) -> untyped
    def after_end(column)
      exclude_end? ? column.gteq(end_time) : column.gt(end_time)
    end

    #: () -> Range[Time]
    def query_range
      exclude_end? ? (begin_time...end_time) : (begin_time..end_time)
    end

    #: (untyped, boundary: Symbol) -> Time
    def coerce_time(value, boundary:)
      time_value(value).getutc.freeze
    rescue ArgumentError, NoMethodError, TypeError
      raise InvalidTimeRangeError, "`within` #{boundary} must be time-like"
    end

    # Anything else names its instant, and `getutc` reads it without
    # `to_time`, which Active Support 8.0 and older warn will change on a
    # zoned time, and without changing the caller's own value as `utc` does.
    #: (untyped) -> untyped
    def time_value(value)
      return zone.parse(value) || raise(ArgumentError) if value.is_a?(String)
      return zone.local(value.year, value.month, value.day) if calendar_date?(value)

      value
    end

    # An inclusive date end runs through the day: to the next one's start.
    #: (Range[untyped]) -> untyped
    def end_value(range)
      last = range.end
      calendar_date?(last) && !range.exclude_end? ? last.next_day : last
    end

    # A DateTime is a Date too, but names its instant.
    #: (untyped) -> bool
    def calendar_date?(value)
      value.instance_of?(Date)
    end

    #: () -> untyped
    def zone
      time = Time #: untyped
      time.zone || time.find_zone!('UTC')
    end

    #: () -> void
    def validate_order!
      return unless begin_time > end_time

      raise InvalidTimeRangeError, '`within` beginning must not follow its end'
    end
  end
end
