# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reconstructs and caches immutable historical snapshots for one adapter configuration.
  class HistoricalSnapshotStore
    #: (tree: AssociationTree, traversal: AssociationTraversal, normalizer: SnapshotNormalizer, preparer: untyped) -> void
    def initialize(tree:, traversal:, normalizer:, preparer:)
      @tree = tree
      @traversal = traversal
      @normalizer = normalizer
      @preparer = preparer
      @snapshots = {} #: Hash[Array[untyped], RecordSnapshot?]
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def call(root_endpoint, context_endpoint)
      key = snapshot_key(root_endpoint, context_endpoint)
      return @snapshots[key] if @snapshots.key?(key)

      @snapshots[key] = custom(
        root_endpoint,
        context_endpoint,
        tree: @tree,
        normalizer: @normalizer
      )
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def uncached(root_endpoint, context_endpoint)
      custom(
        root_endpoint,
        context_endpoint,
        tree: @tree,
        normalizer: @normalizer
      )
    end

    #: (untyped, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer) -> RecordSnapshot?
    def custom(root_endpoint, context_endpoint, tree:, normalizer:)
      if Endpoint.version?(root_endpoint)
        return snapshot_from_version(
          root_endpoint,
          context_endpoint,
          tree: tree,
          normalizer: normalizer
        )
      end

      snapshot_from_live_root(
        root_endpoint,
        context_endpoint,
        tree: tree,
        normalizer: normalizer
      )
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @normalizer: SnapshotNormalizer
    # @rbs @preparer: untyped
    # @rbs @snapshots: Hash[Array[untyped], RecordSnapshot?]

    #: (untyped, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer) -> RecordSnapshot?
    def snapshot_from_version(root_version, context_version, tree:, normalizer:)
      model_class = Endpoint.model_class(root_version)
      @preparer.call(model_class, historical: true)
      @traversal.ensure_habtm_history!(model_class, root_version)
      record = root_version.reify(dup: true)
      normalize(
        record,
        context_version,
        tree: tree,
        normalizer: normalizer,
        habtm_version: root_version
      )
    end

    #: (untyped, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer) -> RecordSnapshot?
    def snapshot_from_live_root(root_record, context_version, tree:, normalizer:)
      record = Endpoint.reload_record(root_record)
      @preparer.call(record.class, historical: true)
      normalize(
        record,
        context_version,
        tree: tree,
        normalizer: normalizer,
        habtm_version: context_version
      )
    end

    #: (untyped, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer, habtm_version: untyped) -> RecordSnapshot?
    def normalize(record, context_version, tree:, normalizer:, habtm_version:)
      reifier = HistoricalAssociationReifier.new(context_version, habtm_version: habtm_version)
      reflections = [] #: Array[untyped]
      reflections = @traversal.reflections_for(record.class, tree, path: '') if record
      reifier.reify(record, reflections) if record && !reflections.empty?
      normalizer.call(record, reifier: reifier)
    end

    #: (untyped, untyped) -> Array[untyped]
    def snapshot_key(root_endpoint, context_endpoint)
      [
        root_endpoint.class.name,
        root_endpoint.id,
        context_endpoint.class.name,
        context_endpoint.id
      ]
    end
  end
end
