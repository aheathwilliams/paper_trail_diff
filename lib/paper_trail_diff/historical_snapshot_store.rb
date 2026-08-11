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
      @live_graph_collector = LiveGraphCollector.new(tree: tree, traversal: traversal)
      @snapshots = {} #: Hash[Array[untyped], RecordSnapshot?]
      @prepared_history = nil #: PreparedHistory?
      @prepared_histories = {} #: Hash[Array[untyped], PreparedHistory]
    end

    #: (untyped, Array[untyped], ?start_at: untyped, ?end_at: untyped) -> void
    def prepare(
      record,
      root_versions,
      start_at: root_versions.first.created_at,
      end_at: root_versions.last.created_at
    )
      return if @tree.empty?
      # A batched preparation already covers these roots.
      return if root_versions.any? { |v| @prepared_histories.key?(context_key(v)) }

      @prepared_history = PreparedHistoryLoader.new(
        record,
        root_versions: root_versions,
        start_at: start_at,
        end_at: end_at,
        tree: @tree,
        traversal: @traversal
      ).call
    end

    #: (Array[untyped], Array[untyped]) -> void
    def prepare_batch(records, root_versions)
      return if @tree.empty? || records.empty? || root_versions.empty?

      Instrumentation.instrument('prepare_history', batch_payload(records, root_versions)) do
        register_batch(records, root_versions)
      end
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def call(root_endpoint, context_endpoint)
      key = snapshot_key(root_endpoint, context_endpoint)
      return @snapshots[key] if @snapshots.key?(key)

      @snapshots[key] = uncached(root_endpoint, context_endpoint)
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

    #: (untyped, habtm_version: untyped) -> untyped
    def association_reader(context_version, habtm_version:)
      fallback = HistoricalAssociationReifier.new(
        context_version,
        habtm_version: habtm_version
      )
      history = @prepared_histories[context_key(context_version)] || @prepared_history
      return fallback unless history

      PreparedAssociationReifier.new(
        history,
        context_version,
        habtm_boundary: habtm_version,
        fallback: fallback
      )
    end

    #: (untyped) -> [Hash[untyped, untyped], Hash[untyped, untyped]]?
    def record_transition(version)
      history = @prepared_history
      return unless history

      history.record_transition(Endpoint.model_class(version), version.item_id, version)
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @normalizer: SnapshotNormalizer
    # @rbs @preparer: untyped
    # @rbs @live_graph_collector: LiveGraphCollector
    # @rbs @snapshots: Hash[Array[untyped], RecordSnapshot?]
    # @rbs @prepared_history: PreparedHistory?
    # @rbs @prepared_histories: Hash[Array[untyped], PreparedHistory]

    #: (untyped) -> Array[untyped]
    def context_key(endpoint)
      [endpoint.class.name, endpoint.id]
    end

    #: (Array[untyped], Array[untyped]) -> Hash[Symbol, untyped]
    def batch_payload(records, root_versions)
      {
        root_count: records.length,
        version_count: root_versions.length,
        model_type: records.first.class.base_class.name.to_s,
        batched: true
      }
    end

    #: (Array[untyped], Array[untyped]) -> void
    def register_batch(records, root_versions)
      history = PreparedHistoryLoader.new(
        records.first,
        root_ids: records.map(&:id),
        root_versions: root_versions,
        start_at: root_versions.map(&:created_at).min,
        end_at: root_versions.map(&:created_at).max,
        tree: @tree,
        traversal: @traversal,
        live_records: @live_graph_collector.call(records)
      ).call
      root_versions.each { |version| @prepared_histories[context_key(version)] = history }
    end

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
      reifier = association_reader(context_version, habtm_version: habtm_version)
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
