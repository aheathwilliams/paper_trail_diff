# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Chooses explicit-version or wall-clock selection for one timeline request.
  class TimelineRange
    BOUNDARY_SYMBOLS = %i[first].freeze
    # `:last` once named the last version, whose recorded state is the one
    # *before* the latest change, so a range ending there silently dropped it.
    LAST_REMOVED = '`:last` was removed because it left out the latest change: omit `to:` ' \
                   'to end at current state, or pass a version'

    attr_reader :from #: untyped
    attr_reader :to #: untyped
    attr_reader :time_range #: TimeRange?

    #: (untyped, from: untyped, to: untyped, within: untyped, ?version_scope: untyped, ?plan: RootVersionPlan?, ?live_endpoint: untyped) -> void
    def initialize(record, from:, to:, within:, version_scope: nil, plan: nil, live_endpoint: nil) # rubocop:disable Metrics/ParameterLists
      @record = record
      @plan = plan
      @live_endpoint = live_endpoint
      @version_scope = version_scope
      @requested_from = from
      @requested_to = to
      @time_range = build_time_range(within)
      validate_mode!
      @from = resolve(from)
      @to = resolve(to)
      freeze
    end

    # A record with no versions has no first boundary to resolve, which
    # is an empty history rather than a bad request. Both endpoints are
    # required, so only `:first` can resolve to nothing; a window has none.
    #: () -> bool
    def unresolved?
      !time? && (@from.nil? || @to.nil?)
    end

    # A batch may have selected these versions already, in which case reselecting
    # them per record would undo the batching.
    # The plan says which pairs of versions become steps, which a filter can
    # make different from adjacent pairs of the selected versions. A `whole`
    # plan replays every version in the range; see RootVersionSelection.
    #: () -> bool
    def preselected? = !@plan.nil?

    #: (?context_required: bool, ?whole: bool) -> RootVersionPlan
    def select_plan(context_required: false, whole: false)
      preselected = @plan
      return preselected if preselected

      range = time_range
      if range
        return TimeVersionRange.new(
          @record, time_range: range, version_scope: @version_scope,
                   live_endpoint: @live_endpoint
        ).select_plan(context_required: context_required, whole: whole)
      end
      explicit_plan(whole)
    end

    # The plan over the window widened to start at its `reach`: where the
    # earliest transaction across its start began (see PreparedHistoryLoader).
    #: (untyped, context_required: bool) -> RootVersionPlan
    def reach_plan(reach, context_required:)
      range = time_range #: TimeRange
      TimeVersionRange.new(
        @record, time_range: range.widened(reach), version_scope: @version_scope,
                 live_endpoint: @live_endpoint
      ).select_plan(context_required: context_required, whole: true)
    end

    # The plan of what the window reports, from the root versions a `wide`
    # plan replays: those whose transactions end inside the window, bounded
    # by the first that ends after it (see TransactionEnds). The root's own
    # mutations among them are those the wide plan names, which a filter
    # chose.
    #: (RootVersionPlan, TransactionEnds, context_required: bool) -> RootVersionPlan
    def reporting_plan(wide, ends, context_required:)
      inside, after = placed(wide.reconstruction_versions, ends)
      RootVersionSelection.new(
        in_range: inside, selected: inside.select { |version| wide.mutation?(version) },
        after_range: after, windowed: true,
        context_required: context_required,
        live_endpoint: wide.closing_record
      ).call
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
    # @rbs @plan: RootVersionPlan?
    # @rbs @version_scope: untyped
    # @rbs @live_endpoint: untyped
    # @rbs @requested_from: untyped
    # @rbs @requested_to: untyped
    # @rbs @from: untyped
    # @rbs @to: untyped

    # The versions whose transactions end inside the window, and the first
    # whose transaction ends after it.
    #: (Array[untyped], TransactionEnds) -> [Array[untyped], untyped]
    def placed(versions, ends)
      range = time_range #: TimeRange
      started = versions.reject { |version| ends.last(version).created_at < begin_time }
      inside, after = started.partition { |version| range.include?(ends.last(version).created_at) }
      [inside, after.first]
    end

    #: (bool) -> RootVersionPlan
    def explicit_plan(whole)
      return RootVersionPlan.empty if unresolved?
      if Endpoint.record?(@to)
        return VersionRange.new(@record, from: @from, to: @from, version_scope: @version_scope)
                           .select_plan_through_current(@to, whole: whole)
      end

      VersionRange.new(
        @record, from: @from, to: @to, version_scope: @version_scope
      ).select_plan_for_range(whole: whole)
    end

    #: (untyped) -> bool
    def symbolic?(boundary)
      boundary.instance_of?(Symbol)
    end

    # Resolving `:first` here keeps callers from depending on the
    # order PaperTrail happens to give its versions association, which a caller
    # is also free to reorder.
    #: (untyped) -> untyped
    def resolve(boundary)
      return boundary unless symbolic?(boundary)
      raise InvalidTimelineRangeError, LAST_REMOVED if boundary == :last

      unless BOUNDARY_SYMBOLS.include?(boundary)
        raise InvalidTimelineRangeError,
              "unsupported boundary: #{boundary.inspect}; use :first, a version, or a record"
      end

      ordered_versions.first
    end

    #: () -> untyped
    def ordered_versions
      VersionQuery.chronological(Endpoint.versions(@record))
    end

    # A batch passes each root its window as it read it.
    #: (untyped) -> TimeRange?
    def build_time_range(within)
      return if within.nil?
      return within if within.instance_of?(TimeRange)

      TimeRange.for(within, [@record.class])
    end

    #: () -> void
    def validate_mode!
      if time?
        return if @requested_from.nil? && @requested_to.nil?

        raise InvalidTimelineRangeError, '`within` cannot be combined with `from` or `to`'
      end
      return unless @requested_from.nil? || @requested_to.nil?

      raise InvalidTimelineRangeError, 'provide both `from` and `to`, or provide `within`'
    end
  end
end
