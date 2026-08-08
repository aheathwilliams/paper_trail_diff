# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Compares adjacent root and selected-descendant activity boundaries.
  class ActivityTimelineBuilder
    #: (untyped, from: untyped, to: untyped, tree: AssociationTree, snapshotter: untyped) -> void
    def initialize(record, from:, to:, tree:, snapshotter:)
      @record = record
      @from = from
      @to = to
      @tree = tree
      @snapshotter = snapshotter
    end

    #: () -> Array[Step]
    def build
      root_versions = VersionRange.new(@record, from: @from, to: @to).select
      versions = ActivityVersionCollector.new(
        @record,
        root_versions: root_versions,
        tree: @tree,
        traversal: AssociationTraversal.new(@tree)
      ).call
      snapshots = versions.map do |version|
        root_version = root_anchor(root_versions, version)
        @snapshotter.call(root_version, version)
      end
      build_steps(versions, snapshots)
    end

    private

    # @rbs @record: untyped
    # @rbs @from: untyped
    # @rbs @to: untyped
    # @rbs @tree: AssociationTree
    # @rbs @snapshotter: untyped

    #: (Array[untyped], untyped) -> untyped
    def root_anchor(root_versions, activity_version)
      root_versions.find do |root_version|
        Support.compare_versions(root_version, activity_version) >= 0
      end || root_versions.last
    end

    #: (Array[untyped], Array[RecordSnapshot?]) -> Array[Step]
    def build_steps(versions, snapshots)
      versions.each_cons(2).with_index.map do |pair, index|
        Step.new(
          from_version: pair.first,
          to_version: pair.last,
          diff: Engine.compare(snapshots.fetch(index), snapshots.fetch(index + 1))
        )
      end.freeze
    end
  end
end
