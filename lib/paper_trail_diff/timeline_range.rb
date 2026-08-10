# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Chooses explicit-version or wall-clock selection for one timeline request.
  class TimelineRange
    attr_reader :from #: untyped
    attr_reader :to #: untyped
    attr_reader :time_range #: TimeRange?

    #: (untyped, from: untyped, to: untyped, within: untyped) -> void
    def initialize(record, from:, to:, within:)
      @record = record
      @from = from
      @to = to
      @time_range = build_time_range(within)
      validate_mode!
      freeze
    end

    #: (?context_required: bool) -> Array[untyped]
    def select(context_required: false)
      range = time_range
      if range
        return TimeVersionRange.new(@record, time_range: range).select(
          context_required: context_required
        )
      end

      VersionRange.new(@record, from: @from, to: @to).select
    end

    #: () -> bool
    def time?
      !time_range.nil?
    end

    #: () -> Time?
    def begin_time
      time_range&.begin_time
    end

    #: (untyped) -> bool
    def include?(version)
      range = time_range
      !range || range.include?(version.created_at)
    end

    private

    # @rbs @record: untyped
    # @rbs @from: untyped
    # @rbs @to: untyped

    #: (untyped) -> TimeRange?
    def build_time_range(within)
      TimeRange.new(within) unless within.nil?
    end

    #: () -> void
    def validate_mode!
      if time?
        return if @from.nil? && @to.nil?

        raise InvalidTimelineRangeError, '`within` cannot be combined with `from` or `to`'
      end
      return unless @from.nil? || @to.nil?

      raise InvalidTimelineRangeError, 'provide both `from` and `to`, or provide `within`'
    end
  end
end
