# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Prepares the association history of a batch's roots, once per model class
  # across every version the batch replays, then analyzes each root from its
  # plan over its own window. AnalysisBatch and DeletedAnalysisBatch differ
  # only in how they find their roots and plans.
  class BatchedRootAnalyses
    # A root whose window moved to the start of a transaction crossing its
    # edge has its window in `windows`; the others take `time_range`.
    #: (time_range: TimeRange?, windows: Hash[Array[String], TimeRange], history_preparer: untyped, analyzer: untyped) -> void
    def initialize(time_range:, windows:, history_preparer:, analyzer:)
      @time_range = time_range
      @windows = windows
      @history_preparer = history_preparer
      @analyzer = analyzer
    end

    # Preparation reads the roots' current association state as a fallback,
    # so a batch that has already loaded them passes them as `loaded`, rather
    # than have preparation walk that state one root at a time.
    #: (Array[untyped], Hash[Array[String], RootVersionPlan], ?loaded: Hash[Array[String], untyped]) -> Hash[Array[String], Analysis]
    def call(records, plans, loaded: {})
      records.group_by(&:class).each_value { |group| prepare(group, plans, loaded) }
      records.to_h do |record|
        key = Endpoint.identity(record)
        window = @windows.fetch(key, @time_range)
        [Support.immutable_copy(key), analysis(record, plans.fetch(key), window)]
      end
    end

    private

    # @rbs @time_range: TimeRange?
    # @rbs @windows: Hash[Array[String], TimeRange]
    # @rbs @history_preparer: untyped
    # @rbs @analyzer: untyped

    # Roots that close on their current state are prepared even without a
    # version in the window, since their descendants may have changed there.
    #: (Array[untyped], Hash[Array[String], RootVersionPlan], Hash[Array[String], untyped]) -> void
    def prepare(records, plans, loaded)
      selected = records.map { |record| plans.fetch(Endpoint.identity(record)) }
      versions = selected.flat_map(&:reconstruction_versions)
      live = selected.any?(&:closing_record)
      return if versions.empty? && !live

      roots = records.map { |record| loaded.fetch(Endpoint.identity(record), record) }
      @history_preparer.call(roots, versions, **preparation_range(versions, live: live))
    end

    # A plan closing on the live record reads history up to now; the others
    # stop at the window's end or at the last version they replay past it, so
    # a past window does not load everything since.
    #: (Array[untyped], live: bool) -> Hash[Symbol, untyped]
    def preparation_range(versions, live:)
      ends = [versions.map(&:created_at).max, @time_range&.end_time, (Time.now.utc if live)]
      { start_at: TransactionCut.earliest_start(@time_range, @windows), end_at: ends.compact.max }
    end

    # A root with no versions in range has nothing to report, which is an
    # empty result rather than a failed request -- unless it closes on its
    # current state, where its descendants may still have moved.
    #: (untyped, RootVersionPlan, TimeRange?) -> Analysis
    def analysis(record, plan, window)
      return @analyzer.empty.with_window(window) if plan.empty? && !plan.closing_record

      @analyzer.call(record, plan, window).with_window(window)
    end
  end
end
