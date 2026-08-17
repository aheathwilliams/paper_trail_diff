# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # PaperTrail/ActiveRecord boundary that produces plain record snapshots. It is
  # deliberately the widest class here: it fronts every public operation and is
  # the only place allowed to know about both PaperTrail and the pure engine.
  # Reconstruction logic lives in the collaborators it wires together.
  class PaperTrailAdapter # rubocop:disable Metrics/ClassLength
    # The only thing a wall-clock window can close on besides a later version.
    CLOSE_ON_CURRENT = :current

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
        notify_ambiguous_association_boundary(from_endpoint, to_endpoint)
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

    #: (untyped, from: untyped, to: untyped, within: untyped, ?version_scope: untyped, ?close_on: Symbol?) -> Array[Step]
    def timeline(record, from:, to:, within:, version_scope: nil, close_on: nil) # rubocop:disable Metrics/ParameterLists
      @traversal_preparer.call(record.class, historical: true)
      TimelineBuilder.new(
        record,
        from: from,
        to: to,
        within: within,
        version_scope: version_scope,
        live_endpoint: live_endpoint_for(record, close_on, within),
        snapshotter: @timeline_snapshotter
      ).build
    end

    #: (untyped, from: untyped, to: untyped, within: untyped, ?version_scope: untyped, ?close_on: Symbol?, ?snapshots: bool, ?group: Symbol?) -> Array[ActivityStep]
    def activity_timeline(record, from:, to:, within:, version_scope: nil, close_on: nil, snapshots: false, group: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      payload = @instrumentation_payload.merge(model_type: record.class.base_class.name.to_s)
      Instrumentation.instrument('activity_timeline', payload) do
        @traversal_preparer.call(record.class, historical: true)
        live = live_endpoint_for(record, close_on, within)
        reject_live_habtm_activity!(record.class) if Endpoint.record?(to) || live
        steps = activity_builder(
          record, from: from, to: to, within: within, version_scope: version_scope,
                  live_endpoint: live, snapshots: snapshots, group: group
        ).build
        payload[:step_count] = steps.length
        steps
      end
    end

    #: (untyped, from: untyped, to: untyped, within: untyped, ?activity: bool, ?version_scope: untyped, ?close_on: Symbol?, ?snapshots: bool, ?group: Symbol?) -> Analysis
    def analyze(record, from:, to:, within:, activity: false, version_scope: nil, close_on: nil, snapshots: false, group: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      @traversal_preparer.call(record.class, historical: true)
      live = live_endpoint_for(record, close_on, within)
      if activity
        return analyze_activity(
          record, from: from, to: to, within: within, version_scope: version_scope,
                  live_endpoint: live, snapshots: snapshots, group: group
        )
      end

      TimelineBuilder.new(
        record, from: from, to: to, within: within, version_scope: version_scope,
                live_endpoint: live, snapshotter: @timeline_snapshotter
      ).analyze
    end

    # Analyzes many roots over one shared range, preparing their history once.
    #: (Array[untyped], within: untyped, ?activity: bool, ?version_scope: untyped, ?close_on: Symbol?) -> Hash[identity, Analysis]
    def analyze_many(records, within:, activity: false, version_scope: nil, close_on: nil)
      count = records.is_a?(Array) ? records.length : 0
      payload = @instrumentation_payload.merge(comparison_count: count)
      Instrumentation.instrument('analyze_many', payload) do
        AnalysisBatch.new(
          records,
          time_range: within.nil? ? nil : TimeRange.new(within),
          version_scope: version_scope,
          close_on_current: close_on_current?(close_on, within),
          live_loader: @live_endpoints.method(:call),
          history_preparer: @historical_store.method(:prepare_batch),
          analyzer: batched_root_analyzer(activity)
        ).call
      end
    end

    # Selects the roots from a relation before running the ordinary batch, so a
    # caller reporting on a population does not have to rediscover which of its
    # members changed. The roots the relation could not reach come back named
    # rather than dropped -- see `PaperTrailDiff.analyze_scope`.
    #: (untyped, limit: Integer?, within: untyped, ?activity: bool, ?version_scope: untyped, ?close_on: Symbol?) -> ScopedAnalysis
    def analyze_scope(scope, limit:, within:, activity: false, version_scope: nil, close_on: nil) # rubocop:disable Metrics/ParameterLists
      raise ConfigurationError, 'limit: is required when selecting roots by scope' if limit.nil?

      selection = ScopedRootSelection.new(
        scope, time_range: within.nil? ? nil : TimeRange.new(within), limit: limit
      ).call
      ScopedAnalysis.new(
        analyses: analyze_many(selection.records, within: within, activity: activity,
                                                  version_scope: version_scope, close_on: close_on),
        unreachable: selection.unreachable
      )
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

    #: (untyped, from: untyped, to: untyped, within: untyped, version_scope: untyped, live_endpoint: untyped, ?snapshots: bool, ?group: Symbol?) -> Analysis
    def analyze_activity(record, from:, to:, within:, version_scope:, live_endpoint:, snapshots: false, group: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      reject_live_habtm_activity!(record.class) if live_endpoint
      activity_builder(
        record, from: from, to: to, within: within, version_scope: version_scope,
                live_endpoint: live_endpoint, snapshots: snapshots, group: group
      ).analyze
    end

    # Association membership is resolved by timestamp, so endpoints sharing one
    # cannot be told apart and any association change between them is invisible.
    # The result may still be correct -- nothing associated may have changed --
    # and the gem cannot tell which, since not seeing the change is the symptom.
    # So it reports the condition and leaves the judgement to the application.
    #: (untyped, untyped) -> void
    def notify_ambiguous_association_boundary(from_endpoint, to_endpoint)
      return if @association_tree.empty?
      return unless Endpoint.version?(from_endpoint) && Endpoint.version?(to_endpoint)
      return unless from_endpoint.created_at == to_endpoint.created_at

      Instrumentation.notify(
        'ambiguous_association_boundary',
        @instrumentation_payload.merge(
          item_type: from_endpoint.item_type.to_s,
          version_ids: [from_endpoint.id, to_endpoint.id].freeze,
          recorded_at: from_endpoint.created_at
        )
      )
    end

    # `close_on:` names what ends a wall-clock window, so it is meaningless for a
    # range whose endpoints the caller already gave explicitly.
    #: (Symbol?, untyped) -> bool
    def close_on_current?(close_on, within)
      return false if close_on.nil?
      unless close_on == CLOSE_ON_CURRENT
        raise ConfigurationError, "close_on: must be #{CLOSE_ON_CURRENT.inspect} or nil"
      end
      raise ConfigurationError, 'close_on: requires `within`' if within.nil?

      true
    end

    # A destroyed root has no current state to close on, and its own destroy
    # version already terminates the history.
    #: (untyped, Symbol?, untyped) -> untyped
    def live_endpoint_for(record, close_on, within)
      return unless close_on_current?(close_on, within)
      return unless Endpoint.record?(record) && !record.destroyed?

      record
    end

    #: () -> void
    def build_snapshotters
      @historical_store = build_historical_store
      @timeline_snapshotter = TimelineSnapshotProvider.new(
        @historical_store, live_snapshotter: method(:live_snapshot)
      )
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

    #: (untyped, from: untyped, to: untyped, within: untyped, ?version_scope: untyped, ?live_endpoint: untyped, ?snapshots: bool, ?group: Symbol?) -> ActivityTimelineBuilder
    def activity_builder(record, from:, to:, within:, version_scope: nil, live_endpoint: nil, snapshots: false, group: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      ActivityTimelineBuilder.new(
        record,
        range: TimelineRange.new(
          record, from: from, to: to, within: within, version_scope: version_scope,
                  live_endpoint: live_endpoint
        ),
        tree: @association_tree,
        snapshotter: @activity_snapshotter,
        snapshots: snapshots,
        group: group
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
