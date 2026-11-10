# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Prepares the association history of a batch's roots, once per model class
  # across every version the batch replays, then analyzes each root from its
  # plan over the batch's window. AnalysisBatch and DeletedAnalysisBatch
  # differ only in how they find their roots and plans.
  class BatchedRootAnalyses
    # `planner` selects the roots' plans over a window. With `activity`, on
    # associations, a window's roots are read from where the earliest
    # transaction open at its start began, and each reports those that end
    # inside it (see TransactionEnds). Without it each version is reported
    # where it was saved, so the window is read as it is.
    #: (time_range: TimeRange?, planner: untyped, history_preparer: untyped, analyzer: untyped, activity: bool) -> void
    def initialize(time_range:, planner:, history_preparer:, analyzer:, activity:)
      @time_range = time_range
      @activity = activity
      @planner = planner
      @history_preparer = history_preparer
      @analyzer = analyzer
    end

    # Preparation reads the roots' current association state as a fallback,
    # so a batch that has already loaded them passes them as `loaded`, rather
    # than have preparation walk that state one root at a time.
    #: (Array[untyped], ?loaded: Hash[Array[String], untyped]) -> Hash[Array[String], Analysis]
    def call(records, loaded: {})
      plans = {} #: Hash[Array[String], RootVersionPlan]
      records.group_by(&:class).each_value { |group| plans.merge!(prepare(group, loaded)) }
      records.to_h do |record|
        key = Endpoint.identity(record)
        [Support.immutable_copy(key), analysis(record, plans.fetch(key))]
      end
    end

    private

    # @rbs @time_range: TimeRange?
    # @rbs @activity: bool
    # @rbs @planner: untyped
    # @rbs @history_preparer: untyped
    # @rbs @analyzer: untyped

    # The plans the roots are read with: over the window, or from where the
    # earliest transaction open at its start began, when the history read for
    # it says one was.
    #: (Array[untyped], Hash[Array[String], untyped]) -> Hash[Array[String], RootVersionPlan]
    def prepare(records, loaded)
      range = @time_range
      plans = @planner.call(records, range)
      reach = prepare_history(records, plans, loaded, range, reach: @activity && !range.nil?)
      return plans unless reach && range

      range = range.widened(reach)
      plans = @planner.call(records, range)
      prepare_history(records, plans, loaded, range, reach: false)
      plans
    end

    # Roots that close on their current state are prepared even without a
    # version in the window, since their descendants may have changed there.
    #: (Array[untyped], Hash[Array[String], RootVersionPlan], Hash[Array[String], untyped], TimeRange?, reach: bool) -> untyped
    def prepare_history(records, plans, loaded, range, reach:)
      selected = records.map { |record| plans.fetch(Endpoint.identity(record)) }
      versions = selected.flat_map(&:reconstruction_versions)
      live = selected.any?(&:closing_record)
      # Roots gone before a window are still asked how far the transactions
      # open at its start reach, since one of them may have destroyed them.
      return if versions.empty? && !live && !reach

      @history_preparer.call(current(records, loaded), versions,
                             reach: reach, **preparation_range(versions, range, live: live))
    end

    # Each root as the batch loaded it, where it did.
    #: (Array[untyped], Hash[Array[String], untyped]) -> Array[untyped]
    def current(records, loaded)
      records.map { |record| loaded.fetch(Endpoint.identity(record), record) }
    end

    # A plan closing on the live record reads history up to now; the others
    # stop at the window's end or at the last version they replay past it, so
    # a past window does not load everything since.
    #: (Array[untyped], TimeRange?, live: bool) -> Hash[Symbol, untyped]
    def preparation_range(versions, range, live:)
      ends = [versions.map(&:created_at).max, range&.end_time, (Time.now.utc if live)]
      { start_at: range&.begin_time, end_at: ends.compact.max }
    end

    # A root with no versions in range has nothing to report, which is an
    # empty result rather than a failed request -- unless it closes on its
    # current state, where its descendants may still have moved.
    #: (untyped, RootVersionPlan) -> Analysis
    def analysis(record, plan)
      window = @time_range
      return @analyzer.empty.with_window(window) if plan.empty? && !plan.closing_record

      @analyzer.call(record, plan, window).with_window(window)
    end
  end
end
