# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Builds one root's Analysis inside a batch, from versions the batch already
  # selected and history it already prepared.
  class BatchedRootAnalyzer
    #: (tree: AssociationTree, timeline_snapshotter: untyped, activity_snapshotter: untyped, preparer: untyped, activity: bool, view: ActivityView) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      tree:, timeline_snapshotter:, activity_snapshotter:, preparer:, activity:, view:
    )
      @tree = tree
      @timeline_snapshotter = timeline_snapshotter
      @activity_snapshotter = activity_snapshotter
      @preparer = preparer
      @activity = activity
      @view = view
    end

    # `window` is the root's window as the batch moved it to transaction edges,
    # or nil when the batch reads each root's whole history.
    #: (untyped, RootVersionPlan, TimeRange?) -> Analysis
    def call(record, plan, window)
      @preparer.call(record.class, historical: true)
      return activity_analysis(record, plan, window) if @activity

      TimelineBuilder.new(
        record,
        from: plan.versions.first,
        to: plan.final_endpoint,
        within: nil,
        plan: plan,
        snapshotter: @timeline_snapshotter
      ).analyze
    end

    # The result for a root with nothing to read.
    #: () -> Analysis
    def empty
      Analysis.empty(activity: @activity)
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @timeline_snapshotter: untyped
    # @rbs @activity_snapshotter: untyped
    # @rbs @preparer: untyped
    # @rbs @activity: bool
    # @rbs @view: ActivityView

    #: (untyped, RootVersionPlan, TimeRange?) -> Analysis
    def activity_analysis(record, plan, window)
      range = TimelineRange.new(
        record, from: (plan.versions.first unless window), to: (plan.final_endpoint unless window),
                within: window, plan: plan
      )
      ActivityTimelineBuilder.new(
        record, range: range, tree: @tree, snapshotter: @activity_snapshotter, view: @view
      ).analyze
    end
  end
end
