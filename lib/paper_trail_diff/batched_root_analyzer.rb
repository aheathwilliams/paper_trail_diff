# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Builds one root's Analysis inside a batch, from versions the batch already
  # selected and history it already prepared.
  class BatchedRootAnalyzer
    #: (tree: AssociationTree, timeline_snapshotter: untyped, activity_snapshotter: untyped, preparer: untyped, activity: bool, view: ActivityView, ?within: untyped) -> void
    def initialize(tree:, timeline_snapshotter:, activity_snapshotter:, preparer:, activity:, view:, within: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      @tree = tree
      @timeline_snapshotter = timeline_snapshotter
      @activity_snapshotter = activity_snapshotter
      @preparer = preparer
      @activity = activity
      @view = view
      @within = within
    end

    # `window` is the root's window as the batch moved it to transaction edges.
    #: (untyped, RootVersionPlan, ?TimeRange?) -> Analysis
    def call(record, plan, window = nil)
      @preparer.call(record.class, historical: true)
      return activity_analysis(record, plan, window) if @activity

      TimelineBuilder.new(
        record,
        from: plan.versions.first,
        to: plan.closing_record || plan.versions.last,
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
    # @rbs @within: untyped
    # @rbs @view: ActivityView

    #: (untyped, RootVersionPlan, TimeRange?) -> Analysis
    def activity_analysis(record, plan, window)
      range = TimelineRange.new(
        record, from: (@within ? nil : plan.versions.first),
                to: (@within ? nil : plan.closing_record || plan.versions.last),
                within: (window || @within if @within), plan: plan
      )
      ActivityTimelineBuilder.new(
        record, range: range, tree: @tree, snapshotter: @activity_snapshotter, view: @view
      ).analyze
    end
  end
end
