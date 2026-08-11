# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Builds one root's Analysis inside a batch, from versions the batch already
  # selected and history it already prepared.
  class BatchedRootAnalyzer
    #: (tree: AssociationTree, timeline_snapshotter: untyped, activity_snapshotter: untyped, preparer: untyped, activity: bool) -> void
    def initialize(tree:, timeline_snapshotter:, activity_snapshotter:, preparer:, activity:)
      @tree = tree
      @timeline_snapshotter = timeline_snapshotter
      @activity_snapshotter = activity_snapshotter
      @preparer = preparer
      @activity = activity
    end

    #: (untyped, Array[untyped]) -> Analysis
    def call(record, versions)
      @preparer.call(record.class, historical: true)
      return activity_analysis(record, versions) if @activity

      TimelineBuilder.new(
        record,
        from: versions.first,
        to: versions.last,
        within: nil,
        versions: versions,
        snapshotter: @timeline_snapshotter
      ).analyze
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @timeline_snapshotter: untyped
    # @rbs @activity_snapshotter: untyped
    # @rbs @preparer: untyped
    # @rbs @activity: bool

    #: (untyped, Array[untyped]) -> Analysis
    def activity_analysis(record, versions)
      range = TimelineRange.new(
        record, from: versions.first, to: versions.last, within: nil, versions: versions
      )
      ActivityTimelineBuilder.new(
        record, range: range, tree: @tree, snapshotter: @activity_snapshotter
      ).analyze
    end
  end
end
