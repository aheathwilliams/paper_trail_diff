# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Validates and applies a wall-clock range without loading model state.
  #
  # A Date is a whole day and a String a local time, both in Time.zone, as
  # Rails reads them, or in UTC without one: never the server's own zone. An
  # inclusive Date end runs through that day. An endless range has no end:
  # it runs through every version saved since it began, whatever the clock
  # that dated them read, as a report through the current state does.
  class TimeRange
    MICROSECOND_DIGITS = 6

    attr_reader :begin_time #: Time
    attr_reader :end_time #: Time?

    # A window over the versions of `models`, its edges cut to the digits
    # their version tables keep. Active Record cuts a time it binds to the
    # precision of the column it is compared with, so an edge left finer than
    # a table that keeps whole seconds would select versions in SQL by the
    # cut time and in Ruby by the whole one. Tables that differ take the
    # coarsest, so that every check of one window cuts it alike.
    #: (untyped, Array[untyped]) -> TimeRange
    def self.for(value, models)
      new(value, digits: models.filter_map do |model|
        stored_digits(model)
      end.min || MICROSECOND_DIGITS)
    end

    # The fractional digits a model's version table keeps for `created_at`,
    # or nil for a model without versions. A column without a precision
    # keeps whatever the adapter writes, which is microseconds.
    #: (untyped) -> Integer?
    def self.stored_digits(model)
      return unless Support.versioned?(model)

      precision = model.paper_trail.version_class.type_for_attribute('created_at').precision
      [precision || MICROSECOND_DIGITS, MICROSECOND_DIGITS].min
    end
    private_class_method :stored_digits

    #: (untyped, ?digits: Integer) -> void
    def initialize(value, digits: MICROSECOND_DIGITS)
      unless value.is_a?(Range) && value.begin
        raise InvalidTimeRangeError, '`within` must be a Range with a beginning'
      end

      @digits = digits

      @begin_time = coerce_time(value.begin, boundary: :begin)
      last = value.end
      @exclude_end = !last.nil? && (value.exclude_end? || calendar_date?(last))
      @end_time = (coerce_time(end_value(value), boundary: :end) unless last.nil?)
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

      finish = end_time
      return true unless finish

      exclude_end? ? timestamp < finish : timestamp <= finish
    end

    #: (untyped) -> untyped
    def scope(relation)
      relation.where(created_at: to_range)
    end

    # The window as a Ruby range, its end included or left out as given, or
    # endless.
    #: () -> Range[Time?]
    def to_range
      exclude_end? ? (begin_time...end_time) : (begin_time..end_time)
    end

    # The window widened to start at `earliest`, where that is before it:
    # what a window reads when a transaction crosses its start (see
    # PreparedHistoryLoader).
    #: (untyped) -> TimeRange
    def widened(earliest)
      start = [earliest, begin_time].min
      self.class.new(Range.new(start, end_time, exclude_end?), digits: @digits)
    end

    # The versions after the window; none follows an endless one.
    #: (untyped) -> untyped
    def trailing_scope(relation)
      finish = end_time
      finish ? after(relation, finish) : relation.none
    end

    # Each item's earliest version after the range, keyed by item id. The
    # versions at each item's earliest instant come back from a NOT EXISTS
    # rather than a window function, so the query stays portable. A timestamp
    # tie keeps the lower id when ids order it, and raises when they cannot.
    #: (untyped) -> Hash[String, untyped]
    def first_trailing_versions(relation)
      finish = end_time
      return {} unless finish

      first_after = VersionQuery.no_earlier_version(relation.arel_table) do |earlier|
        after_end(earlier[:created_at], finish)
      end
      after(relation, finish).where(first_after).group_by { |version| version.item_id.to_s }
                             .transform_values { |tied| Support.earliest_version(tied) }
    end

    private

    # @rbs @exclude_end: bool
    # @rbs @digits: Integer

    #: (untyped, Time) -> untyped
    def after(relation, finish)
      relation.where(after_end(relation.arel_table[:created_at], finish))
    end

    #: (untyped, Time) -> untyped
    def after_end(column, finish)
      exclude_end? ? column.gteq(finish) : column.gt(finish)
    end

    # Cut to the microsecond, as adapters write a time they bind, or to the
    # fewer digits the versions' column keeps: a finer edge would select
    # versions in SQL by the cut time but in Ruby by the whole one, and a
    # version in the edge's microsecond or second would be in one method's
    # window and not another's.
    #: (untyped, boundary: Symbol) -> Time
    def coerce_time(value, boundary:)
      time_value(value).getutc.floor(@digits).freeze
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
      finish = end_time
      return unless finish && begin_time > finish

      raise InvalidTimeRangeError, '`within` beginning must not follow its end'
    end
  end
end
