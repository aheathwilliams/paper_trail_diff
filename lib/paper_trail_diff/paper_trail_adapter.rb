# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # PaperTrail/ActiveRecord boundary that produces plain record snapshots. It is
  # deliberately the widest class here: it fronts every public operation and is
  # the only place allowed to know about both PaperTrail and the pure engine.
  # Reconstruction logic lives in the collaborators it wires together.
  class PaperTrailAdapter # rubocop:disable Metrics/ClassLength
    #: (associations: Array[String | Symbol], ignore: ignore_option, ?reload_live_endpoints: bool) -> void
    def initialize(associations:, ignore:, reload_live_endpoints: true)
      @association_tree = AssociationTree.build(associations)
      @ignore_policy = IgnorePolicy.build(ignore, association_paths: @association_tree.paths)
      @traversal = AssociationTraversal.new(@association_tree)
      @traversal_preparer = TraversalPreparer.new(tree: @association_tree, traversal: @traversal)
      @live_endpoints = LiveEndpointProvider.new(
        tree: @association_tree, traversal: @traversal, reload: reload_live_endpoints
      )
      @instrumentation_payload = @live_endpoints.comparison_payload
      @snapshot_pool = SnapshotPool.new
      @normalizer = SnapshotNormalizer.new(
        tree: @association_tree, ignore_policy: @ignore_policy,
        traversal: @traversal, pool: @snapshot_pool
      )
      build_snapshotters
    end

    #: (untyped, untyped) -> Diff
    def compare(from_endpoint, to_endpoint)
      payload = @instrumentation_payload.merge(comparison_count: 1)
      Instrumentation.instrument('compare', payload) do
        Endpoint.validate_pair!(from_endpoint, to_endpoint)
        Engine.compare(snapshot_for_endpoint(from_endpoint), snapshot_for_endpoint(to_endpoint))
      end
    end

    # Compares independent pairs and returns immutable results keyed by item identity.
    #: (Array[comparison_input]) -> comparison_results
    def compare_many(comparisons)
      count = comparisons.is_a?(Array) ? comparisons.length : 0
      payload = @instrumentation_payload.merge(comparison_count: count)
      Instrumentation.instrument('compare_many', payload) do
        ComparisonBatch.new(
          comparisons,
          live_loader: @live_endpoints.method(:call), preparer: @traversal_preparer.method(:call),
          history_preparer: @historical_store.method(:prepare_batch),
          historical_snapshotter: method(:historical_snapshot),
          live_normalizer: method(:normalize_live_snapshot)
        ).call
      end
    end

    #: (untyped, from: untyped, to: untyped, within: untyped) -> Array[Step]
    def timeline(record, from:, to:, within:)
      @traversal_preparer.call(record.class, historical: true)
      builder = TimelineBuilder.new(
        record,
        from: from,
        to: to,
        within: within,
        snapshotter: @timeline_snapshotter
      )
      builder.build
    end

    #: (untyped, from: untyped, to: untyped, within: untyped) -> Array[ActivityStep]
    def activity_timeline(record, from:, to:, within:)
      payload = @instrumentation_payload.merge(model_type: record.class.base_class.name.to_s)
      Instrumentation.instrument('activity_timeline', payload) do
        @traversal_preparer.call(record.class, historical: true)
        reject_live_habtm_activity!(record.class) if Endpoint.record?(to)
        steps = activity_builder(record, from: from, to: to, within: within).build
        payload[:step_count] = steps.length
        steps
      end
    end

    #: (untyped, from: untyped, to: untyped, within: untyped, ?activity: bool) -> Analysis
    def analyze(record, from:, to:, within:, activity: false)
      if activity
        @traversal_preparer.call(record.class, historical: true)
        return activity_builder(record, from: from, to: to, within: within).analyze
      end

      @traversal_preparer.call(record.class, historical: true)
      TimelineBuilder.new(
        record,
        from: from,
        to: to,
        within: within,
        snapshotter: @timeline_snapshotter
      ).analyze
    end

    # Analyzes many roots over one shared range, preparing their history once.
    #: (Array[untyped], within: untyped, ?activity: bool, ?version_scope: untyped) -> Hash[identity, Analysis]
    def analyze_many(records, within:, activity: false, version_scope: nil)
      count = records.is_a?(Array) ? records.length : 0
      payload = @instrumentation_payload.merge(comparison_count: count)
      Instrumentation.instrument('analyze_many', payload) do
        AnalysisBatch.new(
          records,
          time_range: within.nil? ? nil : TimeRange.new(within),
          version_scope: version_scope,
          live_loader: @live_endpoints.method(:call),
          history_preparer: @historical_store.method(:prepare_batch),
          analyzer: batched_root_analyzer(activity)
        ).call
      end
    end

    private

    # @rbs @association_tree: AssociationTree
    # @rbs @live_endpoints: LiveEndpointProvider
    # @rbs @instrumentation_payload: Hash[Symbol, untyped]
    # @rbs @ignore_policy: IgnorePolicy
    # @rbs @traversal: AssociationTraversal
    # @rbs @traversal_preparer: TraversalPreparer
    # @rbs @snapshot_pool: SnapshotPool
    # @rbs @normalizer: SnapshotNormalizer
    # @rbs @historical_store: HistoricalSnapshotStore
    # @rbs @timeline_snapshotter: TimelineSnapshotProvider
    # @rbs @activity_snapshotter: ActivitySnapshotProvider

    #: () -> void
    def build_snapshotters
      @historical_store = build_historical_store
      @timeline_snapshotter = TimelineSnapshotProvider.new(@historical_store)
      @activity_snapshotter = build_activity_snapshotter
    end

    #: (bool) -> BatchedRootAnalyzer
    def batched_root_analyzer(activity)
      BatchedRootAnalyzer.new(
        tree: @association_tree,
        timeline_snapshotter: @timeline_snapshotter,
        activity_snapshotter: @activity_snapshotter,
        preparer: @traversal_preparer.method(:call),
        activity: activity
      )
    end

    #: () -> HistoricalSnapshotStore
    def build_historical_store
      HistoricalSnapshotStore.new(
        tree: @association_tree,
        traversal: @traversal,
        normalizer: @normalizer,
        preparer: @traversal_preparer.method(:call)
      )
    end

    #: () -> ActivitySnapshotProvider
    def build_activity_snapshotter
      refresher = BranchSnapshotRefresher.new(
        tree: @association_tree, ignore_policy: @ignore_policy,
        traversal: @traversal, pool: @snapshot_pool,
        normalizer: @normalizer,
        full_snapshotter: method(:snapshot_at),
        partial_snapshotter: @historical_store.method(:custom),
        association_reader: @historical_store.method(:association_reader),
        record_transition: @historical_store.method(:record_transition)
      )
      ActivitySnapshotProvider.new(
        snapshotter: method(:snapshot_at),
        refresher: refresher,
        preparer: @historical_store.method(:prepare)
      )
    end

    #: (untyped, from: untyped, to: untyped, within: untyped) -> ActivityTimelineBuilder
    def activity_builder(record, from:, to:, within:)
      ActivityTimelineBuilder.new(
        record,
        range: TimelineRange.new(record, from: from, to: to, within: within),
        tree: @association_tree,
        snapshotter: @activity_snapshotter
      )
    end

    #: (untyped) -> void
    def reject_live_habtm_activity!(model_class)
      paths = @traversal.habtm_paths(model_class)
      return if paths.empty?

      message = "live-ended activity cannot reconstruct HABTM event boundaries: #{paths.join(', ')}"
      raise UnsupportedLiveActivityError, message
    end

    #: (untyped) -> RecordSnapshot?
    def snapshot_for_endpoint(endpoint)
      Endpoint.version?(endpoint) ? historical_snapshot(endpoint) : live_snapshot(endpoint)
    end

    #: (untyped) -> RecordSnapshot?
    def historical_snapshot(version)
      snapshot_at(version, version)
    end

    #: (untyped) -> RecordSnapshot?
    def uncached_historical_snapshot(version)
      @historical_store.uncached(version, version)
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def snapshot_at(root_endpoint, context_endpoint)
      return live_snapshot(root_endpoint) if Endpoint.record?(context_endpoint)

      @historical_store.call(root_endpoint, context_endpoint)
    end

    #: (untyped) -> RecordSnapshot
    def live_snapshot(record)
      current = @live_endpoints.call([record]).fetch(Endpoint.identity(record))
      normalize_live_snapshot(current)
    end

    #: (untyped) -> RecordSnapshot
    def normalize_live_snapshot(current)
      @traversal_preparer.call(current.class, historical: false)
      @normalizer.call(current, reifier: LiveAssociationReader.new) ||
        raise(InvalidEndpointError, 'current record endpoint could not be normalized')
    end
  end
end
