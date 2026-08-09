# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # PaperTrail/ActiveRecord boundary that produces plain record snapshots.
  class PaperTrailAdapter
    #: (associations: Array[String | Symbol], ignore: ignore_option) -> void
    def initialize(associations:, ignore:)
      @association_tree = AssociationTree.build(associations)
      @ignore_policy = IgnorePolicy.build(ignore, association_paths: @association_tree.paths)
      @traversal = AssociationTraversal.new(@association_tree)
      @snapshot_pool = SnapshotPool.new
      @normalizer = SnapshotNormalizer.new(
        tree: @association_tree,
        ignore_policy: @ignore_policy,
        traversal: @traversal,
        pool: @snapshot_pool
      )
      @historical_store = build_historical_store
      @activity_snapshotter = build_activity_snapshotter
    end

    #: (untyped, untyped) -> Diff
    def compare(from_endpoint, to_endpoint)
      Endpoint.validate_pair!(from_endpoint, to_endpoint)
      Engine.compare(snapshot_for_endpoint(from_endpoint), snapshot_for_endpoint(to_endpoint))
    end

    #: (untyped, from: untyped, to: untyped) -> Array[Step]
    def timeline(record, from:, to:)
      builder = TimelineBuilder.new(
        record,
        from: from,
        to: to,
        snapshotter: method(:uncached_historical_snapshot)
      )
      builder.build
    end

    #: (untyped, from: untyped, to: untyped) -> Array[ActivityStep]
    def activity_timeline(record, from:, to:)
      prepare_traversal!(record.class, historical: true)
      reject_live_habtm_activity!(record.class) if Endpoint.record?(to)
      ActivityTimelineBuilder.new(
        record,
        from: from,
        to: to,
        tree: @association_tree,
        snapshotter: @activity_snapshotter
      ).build
    end

    #: (untyped, from: untyped, to: untyped, ?activity: bool) -> Analysis
    def analyze(record, from:, to:, activity: false)
      if activity
        prepare_traversal!(record.class, historical: true)
        return activity_builder(record, from: from, to: to).analyze
      end

      TimelineBuilder.new(
        record,
        from: from,
        to: to,
        snapshotter: method(:uncached_historical_snapshot)
      ).analyze
    end

    private

    # @rbs @association_tree: AssociationTree
    # @rbs @ignore_policy: IgnorePolicy
    # @rbs @traversal: AssociationTraversal
    # @rbs @snapshot_pool: SnapshotPool
    # @rbs @normalizer: SnapshotNormalizer
    # @rbs @historical_store: HistoricalSnapshotStore
    # @rbs @activity_snapshotter: ActivitySnapshotProvider

    #: () -> HistoricalSnapshotStore
    def build_historical_store
      HistoricalSnapshotStore.new(
        tree: @association_tree,
        traversal: @traversal,
        normalizer: @normalizer,
        preparer: method(:prepare_traversal!)
      )
    end

    #: () -> ActivitySnapshotProvider
    def build_activity_snapshotter
      refresher = BranchSnapshotRefresher.new(
        tree: @association_tree,
        ignore_policy: @ignore_policy,
        traversal: @traversal,
        pool: @snapshot_pool,
        normalizer: @normalizer,
        full_snapshotter: method(:snapshot_at),
        partial_snapshotter: @historical_store.method(:custom)
      )
      ActivitySnapshotProvider.new(snapshotter: method(:snapshot_at), refresher: refresher)
    end

    #: (untyped, from: untyped, to: untyped) -> ActivityTimelineBuilder
    def activity_builder(record, from:, to:)
      ActivityTimelineBuilder.new(
        record,
        from: from,
        to: to,
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
      current = Endpoint.reload_record(record)
      prepare_traversal!(current.class, historical: false)
      @normalizer.call(current, reifier: LiveAssociationReader.new) ||
        raise(InvalidEndpointError, 'current record endpoint could not be normalized')
    end

    #: (untyped, historical: bool) -> void
    def prepare_traversal!(model_class, historical:)
      return if @association_tree.empty?

      ensure_association_tracking! if historical
      @traversal.validate!(model_class)
    end

    #: () -> void
    def ensure_association_tracking!
      paper_trail = Object.const_get(:PaperTrail) #: untyped
      config = paper_trail.config #: untyped
      available = defined?(::PaperTrailAssociationTracking) &&
                  config.respond_to?(:track_associations?) &&
                  config.track_associations?
      return if available

      message = 'association tracking must be loaded and enabled to compare historical associations'
      raise AssociationTrackingUnavailableError, message
    end
  end
end
