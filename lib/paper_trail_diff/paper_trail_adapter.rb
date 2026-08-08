# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # PaperTrail/ActiveRecord boundary that produces plain record snapshots.
  class PaperTrailAdapter
    #: (associations: Array[String | Symbol], ignore: ignore_option) -> void
    def initialize(associations:, ignore:)
      @association_tree = AssociationTree.build(associations)
      ignore_policy = IgnorePolicy.build(ignore, association_paths: @association_tree.paths)
      @traversal = AssociationTraversal.new(@association_tree)
      @normalizer = SnapshotNormalizer.new(
        tree: @association_tree,
        ignore_policy: ignore_policy,
        traversal: @traversal
      )
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
        snapshotter: method(:historical_snapshot)
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
        snapshotter: method(:snapshot_at)
      ).build
    end

    #: (untyped, from: untyped, to: untyped) -> Analysis
    def analyze(record, from:, to:)
      TimelineBuilder.new(
        record,
        from: from,
        to: to,
        snapshotter: method(:historical_snapshot)
      ).analyze
    end

    private

    # @rbs @association_tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @normalizer: SnapshotNormalizer

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

    #: (untyped, untyped) -> RecordSnapshot?
    def snapshot_at(root_endpoint, context_endpoint)
      return live_snapshot(root_endpoint) if Endpoint.record?(context_endpoint)

      if Endpoint.version?(root_endpoint)
        snapshot_from_version(root_endpoint, context_endpoint)
      else
        snapshot_from_live_root(root_endpoint, context_endpoint)
      end
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def snapshot_from_version(root_version, context_version)
      model_class = Endpoint.model_class(root_version)
      prepare_traversal!(model_class, historical: true)
      @traversal.ensure_habtm_history!(model_class, root_version)
      record = root_version.reify(dup: true)
      normalize_historical(record, context_version, habtm_version: root_version)
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def snapshot_from_live_root(root_record, context_version)
      record = Endpoint.reload_record(root_record)
      prepare_traversal!(record.class, historical: true)
      normalize_historical(record, context_version, habtm_version: context_version)
    end

    #: (untyped) -> RecordSnapshot
    def live_snapshot(record)
      current = Endpoint.reload_record(record)
      prepare_traversal!(current.class, historical: false)
      @normalizer.call(current, reifier: LiveAssociationReader.new) ||
        raise(InvalidEndpointError, 'current record endpoint could not be normalized')
    end

    #: (untyped, untyped, habtm_version: untyped) -> RecordSnapshot?
    def normalize_historical(record, context_version, habtm_version:)
      reifier = HistoricalAssociationReifier.new(context_version, habtm_version: habtm_version)
      reflections = [] #: Array[untyped]
      reflections = @traversal.reflections_for(record.class, @association_tree, path: '') if record
      reifier.reify(record, reflections) if record && !reflections.empty?
      @normalizer.call(record, reifier: reifier)
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
