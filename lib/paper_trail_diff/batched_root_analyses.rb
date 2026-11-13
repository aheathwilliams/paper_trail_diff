# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Prepares the association history of a batch's roots, once per model class
  # across every version the batch replays, then analyzes each root from its
  # plan over the batch's window. AnalysisBatch and DeletedAnalysisBatch
  # differ only in how they find their roots and plans.
  class BatchedRootAnalyses
    # `planner` selects the roots' plans over a window. On associations, a
    # window's history is read from where the earliest transaction open at
    # its start began. With `activity`, the roots are planned from there too,
    # and each reports the transactions that end inside the window (see
    # TransactionEnds). Without it each root version is reported where it
    # was saved, so the roots are planned over the window as it is. `reach`
    # answers where that transaction began, for a model and a window's start
    # (see AssociationTraversal#reach_before).
    #: (time_range: TimeRange?, planner: untyped, history_preparer: untyped, analyzer: untyped, activity: bool, reach: untyped) -> void
    def initialize(time_range:, planner:, history_preparer:, analyzer:, activity:, reach:) # rubocop:disable Metrics/ParameterLists
      @time_range = time_range
      @reach = reach
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
    # @rbs @reach: untyped

    # The plans the roots are read with: over the window, or with activity
    # from where the earliest transaction open at its start began. The
    # history is read from there either way.
    #: (Array[untyped], Hash[Array[String], untyped]) -> Hash[Array[String], RootVersionPlan]
    def prepare(records, loaded)
      window = @time_range
      reach = (@reach.call(records.first.class, window.begin_time) if window)
      range = reach && window ? window.widened(reach) : window
      plans = @planner.call(records, @activity ? range : window)
      prepare_history(records, plans, loaded, range)
      plans
    end

    # Roots that close on their current state are prepared even without a
    # version in the window, since their descendants may have changed there.
    #: (Array[untyped], Hash[Array[String], RootVersionPlan], Hash[Array[String], untyped], TimeRange?) -> void
    def prepare_history(records, plans, loaded, range)
      selected = records.map { |record| plans.fetch(Endpoint.identity(record)) }
      versions = selected.flat_map(&:reconstruction_versions)
      live = selected.any?(&:closing_record)
      return if versions.empty? && !live

      @history_preparer.call(current(records, loaded), versions,
                             **preparation_range(versions, range, live: live))
    end

    # Each root as the batch loaded it, where it did.
    #: (Array[untyped], Hash[Array[String], untyped]) -> Array[untyped]
    def current(records, loaded)
      records.map { |record| loaded.fetch(Endpoint.identity(record), record) }
    end

    # A plan closing on the live record reads history up to now; the others
    # stop at the window's end or where the transactions of the versions they
    # replay past it end, so a past window does not load everything since.
    #: (Array[untyped], TimeRange?, live: bool) -> Hash[Symbol, untyped]
    def preparation_range(versions, range, live:)
      ends = [TransactionCut.ends_at(versions), range&.end_time, (Time.now.utc if live)]
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
