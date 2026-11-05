# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reconstructs and caches immutable historical snapshots for one adapter
  # configuration. It keeps the histories batches prepare, by root and by root
  # version; one prepared for a single root goes back to the caller, who
  # passes it to every read for that root.
  class HistoricalSnapshotStore
    #: (traversal: AssociationTraversal, normalizer: SnapshotNormalizer, preparer: untyped) -> void
    def initialize(traversal:, normalizer:, preparer:)
      @tree = traversal.tree
      @traversal = traversal
      @normalizer = normalizer
      @preparer = preparer
      @prepared_snapshotter = PreparedSnapshotBuilder.new(traversal)
      @live_graph_collector = LiveGraphCollector.new(traversal)
      @snapshots = {} #: Hash[Array[untyped], RecordSnapshot?]
      @prepared_histories = {} #: Hash[Array[untyped], PreparedHistory]
      @batched_roots = {} #: Hash[identity, PreparedHistory]
      @live_roots = {} #: Hash[identity, untyped]
      @live_states = {} #: Hash[identity, PreparedRecordState]
    end

    # A `start_at` is a window's (see PreparedHistoryLoader); a range of
    # versions starts at its first.
    #: (untyped, Array[untyped], ?start_at: untyped, ?end_at: untyped) -> PreparedHistory?
    def prepare(record, root_versions, start_at: nil, end_at: root_versions.last.created_at)
      return if @tree.empty?

      # A batch prepared this root with the others, including a root with no
      # version in the window that closes on its current state.
      batched = @batched_roots[Endpoint.identity(record)]
      return batched if batched

      PreparedHistoryLoader.new(
        record, root_ids: [record.id], root_versions: root_versions,
                start_at: start_at || root_versions.first.created_at, end_at: end_at, tree: @tree,
                traversal: @traversal, live_records: [], window: !start_at.nil?
      ).call
    end

    # A `start_at` is a window's, as for `prepare`. A window's roots may have
    # no version in it, when only their descendants changed there.
    #: (Array[untyped], Array[untyped], ?start_at: untyped, ?end_at: untyped) -> void
    def prepare_batch(records, root_versions, start_at: nil, end_at: nil)
      return if @tree.empty? || records.empty? || (root_versions.empty? && start_at.nil?)

      Instrumentation.instrument('prepare_history', batch_payload(records, root_versions)) do
        register_batch(records, root_versions, start_at: start_at, end_at: end_at)
      end
      # A batch passes its roots as it just loaded them, so the current state
      # they close on is read from them rather than once more per root.
      records.each { |record| @live_roots[Endpoint.identity(record)] = record }
    end

    # Missing roots, and roots compared only between versions, have no live
    # graph to collect. Reading their associations here would issue a query
    # per root and seed nonexistent rows as live state.
    #: (Array[untyped], Array[untyped], ?start_at: untyped, ?end_at: untyped) -> void
    def prepare_deleted_batch(records, root_versions, start_at: nil, end_at: nil)
      return if @tree.empty? || records.empty? || root_versions.empty?

      register_batch(records, root_versions, live_records: [], start_at: start_at, end_at: end_at)
    end

    # `history` is the one `prepare` returned for this root, if any.
    #: (untyped, untyped, ?history: PreparedHistory?) -> RecordSnapshot?
    def call(root_endpoint, context_endpoint, history: nil)
      key = snapshot_key(root_endpoint, context_endpoint)
      return @snapshots[key] if @snapshots.key?(key)

      @snapshots[key] = uncached(root_endpoint, context_endpoint, history: history)
    end

    #: (untyped, untyped, ?history: PreparedHistory?) -> RecordSnapshot?
    def uncached(root_endpoint, context_endpoint, history: nil)
      custom(root_endpoint, context_endpoint, tree: @tree, normalizer: @normalizer,
                                              history: history)
    end

    #: (untyped, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer, ?history: PreparedHistory?) -> RecordSnapshot?
    def custom(root_endpoint, context_endpoint, tree:, normalizer:, history: nil)
      history = history_for(context_endpoint, history)
      if Endpoint.version?(root_endpoint)
        return snapshot_from_version(
          root_endpoint, context_endpoint, tree: tree, normalizer: normalizer, history: history
        )
      end

      snapshot_from_live_root(root_endpoint, context_endpoint, tree: tree, normalizer: normalizer,
                                                               history: history)
    end

    # The state a snapshot of the root at this endpoint starts from when built
    # from prepared history: the one a version stored, or the live row's.
    # Nil where a version's is read another way.
    #: (untyped) -> PreparedRecordState?
    def root_state(root_endpoint)
      return @prepared_snapshotter.state(root_endpoint) if Endpoint.version?(root_endpoint)

      live_state(root_endpoint)
    end

    #: (untyped, habtm_version: untyped, ?history: PreparedHistory?) -> untyped
    def association_reader(context_version, habtm_version:, history: nil)
      fallback = HistoricalAssociationReifier.new(
        context_version,
        habtm_version: habtm_version
      )
      history = history_for(context_version, history)
      return fallback unless history

      PreparedAssociationReifier.new(
        history,
        context_version,
        habtm_boundary: habtm_version,
        fallback: fallback
      )
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @normalizer: SnapshotNormalizer
    # @rbs @preparer: untyped
    # @rbs @prepared_snapshotter: PreparedSnapshotBuilder
    # @rbs @live_graph_collector: LiveGraphCollector
    # @rbs @snapshots: Hash[Array[untyped], RecordSnapshot?]
    # @rbs @prepared_histories: Hash[Array[untyped], PreparedHistory]
    # @rbs @batched_roots: Hash[identity, PreparedHistory]
    # @rbs @live_roots: Hash[identity, untyped]
    # @rbs @live_states: Hash[identity, PreparedRecordState]

    # A batch's history for the version wins over the one a caller passes.
    #: (untyped, PreparedHistory?) -> PreparedHistory?
    def history_for(context_endpoint, history)
      @prepared_histories[Support.row_key(context_endpoint)] || history
    end

    #: (Array[untyped], Array[untyped]) -> Hash[Symbol, untyped]
    def batch_payload(records, root_versions)
      { root_count: records.length, version_count: root_versions.length,
        model_type: records.first.class.base_class.name.to_s, batched: true }
    end

    #: (Array[untyped], Array[untyped], ?live_records: Array[untyped], ?start_at: untyped, ?end_at: untyped) -> void
    def register_batch(records, root_versions, live_records: @live_graph_collector.call(records),
                       start_at: nil, end_at: nil)
      history = PreparedHistoryLoader.new(
        records.first,
        root_ids: records.map(&:id),
        root_versions: root_versions,
        start_at: start_at || root_versions.map(&:created_at).min,
        end_at: end_at || root_versions.map(&:created_at).max,
        tree: @tree,
        traversal: @traversal,
        live_records: live_records,
        window: !start_at.nil?
      ).call
      register(history, records, root_versions)
    end

    # Snapshot reads find the history by root version, and `prepare` by root.
    #: (PreparedHistory, Array[untyped], Array[untyped]) -> void
    def register(history, records, root_versions)
      root_versions.each { |version| @prepared_histories[Support.row_key(version)] = history }
      records.each { |record| @batched_roots[Endpoint.identity(record)] = history }
    end

    #: (untyped, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer, history: PreparedHistory?) -> RecordSnapshot?
    def snapshot_from_version(root_version, context_version, tree:, normalizer:, history:)
      model_class = RecordedClass.for(root_version)
      @preparer.call(model_class, historical: true)
      @traversal.ensure_habtm_history!(model_class, root_version)
      handled, snapshot = @prepared_snapshotter.call(
        root_version, context_version, tree: tree, normalizer: normalizer, history: history
      )
      return snapshot if handled

      record = Support.reify(root_version, dup: true)
      normalize(record, context_version, tree: tree, normalizer: normalizer,
                                         habtm_version: root_version, history: history)
    end

    # Read from prepared history where it can be, as a version is, without
    # instantiating the root's members. Only the fallback, which writes the
    # members it rebuilds onto the root, needs a record of its own.
    #: (untyped, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer, history: PreparedHistory?) -> RecordSnapshot?
    def snapshot_from_live_root(root_record, context_version, tree:, normalizer:, history:)
      state = live_state(root_record)
      @preparer.call(state.model_class, historical: true)
      handled, snapshot = @prepared_snapshotter.live(
        state, context_version, tree: tree, normalizer: normalizer, history: history
      )
      return snapshot if handled

      normalize(live_root(root_record), context_version, tree: tree, normalizer: normalizer,
                                                         habtm_version: context_version,
                                                         history: history)
    end

    # The state of the root's row, read once for the call: every snapshot
    # that starts from the row starts from the same state. Reading it writes
    # nothing to the row, so it is read from the loaded record itself, whose
    # columns the current snapshot reads too.
    #: (untyped) -> PreparedRecordState
    def live_state(root_record)
      identity = Endpoint.identity(root_record)
      @live_states[identity] ||= PreparedRecordState.new(loaded_root(root_record, identity))
    end

    # Rebuilding a version's associations writes them onto the record, so each
    # snapshot that does gets its own copy of the root's row, built from the
    # row's stored values without a query.
    #: (untyped) -> untyped
    def live_root(root_record)
      loaded = loaded_root(root_record, Endpoint.identity(root_record))
      loaded.class.instantiate(loaded.attributes_before_type_cast)
    end

    # A batch loaded the row already; otherwise it is read once, so every
    # snapshot of the call starts from the same row.
    #: (untyped, identity) -> untyped
    def loaded_root(root_record, identity)
      @live_roots[identity] ||= Endpoint.reload_record(root_record)
    end

    #: (untyped, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer, habtm_version: untyped, history: PreparedHistory?) -> RecordSnapshot?
    def normalize(record, context_version, tree:, normalizer:, habtm_version:, history:) # rubocop:disable Metrics/ParameterLists
      reifier = association_reader(context_version, habtm_version: habtm_version, history: history)
      reflections = [] #: Array[untyped]
      reflections = @traversal.reflections_for(record.class, tree, path: '') if record
      reifier.reify(record, reflections) if record && !reflections.empty?
      normalizer.call(record, reifier: reifier)
    end

    #: (untyped, untyped) -> Array[untyped]
    def snapshot_key(root_endpoint, context_endpoint)
      Support.row_key(root_endpoint) + Support.row_key(context_endpoint)
    end
  end
end
