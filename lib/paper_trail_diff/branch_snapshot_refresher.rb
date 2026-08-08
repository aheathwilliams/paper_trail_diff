# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reconstructs selected root branches and merges them into a prior immutable snapshot.
  class BranchSnapshotRefresher
    #: (tree: AssociationTree, ignore_policy: IgnorePolicy, traversal: AssociationTraversal, full_snapshotter: untyped, partial_snapshotter: untyped) -> void
    def initialize(tree:, ignore_policy:, traversal:, full_snapshotter:, partial_snapshotter:)
      @tree = tree
      @ignore_policy = ignore_policy
      @traversal = traversal
      @full_snapshotter = full_snapshotter
      @partial_snapshotter = partial_snapshotter
      @components = {} #: Hash[Array[String], [AssociationTree, SnapshotNormalizer]]
    end

    #: (untyped, untyped, RecordSnapshot?, Array[String]) -> RecordSnapshot?
    def call(root_endpoint, context_endpoint, previous_snapshot, branches)
      return full_snapshot(root_endpoint, context_endpoint) unless previous_snapshot

      tree, normalizer = components(branches)
      partial = @partial_snapshotter.call(
        root_endpoint,
        context_endpoint,
        tree: tree,
        normalizer: normalizer
      )
      return full_snapshot(root_endpoint, context_endpoint) unless partial

      merge(previous_snapshot, partial)
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @ignore_policy: IgnorePolicy
    # @rbs @traversal: AssociationTraversal
    # @rbs @full_snapshotter: untyped
    # @rbs @partial_snapshotter: untyped
    # @rbs @components: Hash[Array[String], [AssociationTree, SnapshotNormalizer]]

    #: (Array[String]) -> [AssociationTree, SnapshotNormalizer]
    def components(branches)
      key = branches.sort.freeze
      @components[key] ||= build_components(key)
    end

    #: (Array[String]) -> [AssociationTree, SnapshotNormalizer]
    def build_components(branches)
      tree = @tree.select(branches)
      normalizer = SnapshotNormalizer.new(
        tree: tree,
        ignore_policy: @ignore_policy,
        traversal: @traversal
      )
      [tree, normalizer]
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def full_snapshot(root_endpoint, context_endpoint)
      @full_snapshotter.call(root_endpoint, context_endpoint)
    end

    #: (RecordSnapshot, RecordSnapshot) -> RecordSnapshot
    def merge(previous, partial)
      RecordSnapshot.new(
        type: previous.type,
        id: previous.id,
        attributes: previous.attributes,
        associations: previous.associations.merge(partial.associations)
      )
    end
  end
end
