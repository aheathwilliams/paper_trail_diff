# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # PaperTrail/ActiveRecord boundary that produces plain record snapshots. It is
  # deliberately the widest class here: it fronts every public operation and is
  # the only place allowed to know about both PaperTrail and the pure engine.
  # Reconstruction logic lives in the collaborators it wires together.
  class PaperTrailAdapter # rubocop:disable Metrics/ClassLength
    # `recorded_changes:` reads what each activity boundary's version recorded.
    # `allow_approximate:` accepts association paths read with PT-AT.
    #: (associations: association_option, ignore: ignore_option, ?reload_live_endpoints: bool, ?recorded_changes: bool, ?allow_approximate: bool) -> void
    def initialize(associations:, ignore:, reload_live_endpoints: true, recorded_changes: false, allow_approximate: false) # rubocop:disable Metrics/MethodLength, Layout/LineLength
      @association_tree = AssociationTree.build(associations)
      @ignore_policy = IgnorePolicy.build(ignore, association_paths: @association_tree.paths)
      @recorded = (@ignore_policy if recorded_changes)
      @traversal = AssociationTraversal.new(@association_tree)
      @traversal_preparer = TraversalPreparer.new(tree: @association_tree, traversal: @traversal,
                                                  allow_approximate: allow_approximate)
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
        ReadSnapshot.call([from_endpoint, to_endpoint]) do
          if @association_tree.empty?
            Engine.compare(snapshot_for_endpoint(from_endpoint), snapshot_for_endpoint(to_endpoint))
          else
            # Prepared history orders versions that share a timestamp and finds
            # children that later moved away; reading associations straight from
            # PT-AT would resolve them by time alone and miss those children.
            comparison_batch([{ from: from_endpoint, to: to_endpoint }],
                             preparer: @traversal_preparer.method(:call)).call.values.fetch(0)
          end
        end
      end
    end

    # Compares independent pairs and returns immutable results keyed by item identity.
    #: (Array[comparison_input]) -> comparison_results
    def compare_many(comparisons)
      count = comparisons.is_a?(Array) ? comparisons.length : 0
      payload = @instrumentation_payload.merge(comparison_count: count)
      Instrumentation.instrument('compare_many', payload) do
        ReadSnapshot.call(comparison_endpoints(comparisons)) do
          comparison_batch(comparisons, preparer: @traversal_preparer.method(:call)).call
        end
      end
    end

    #: (untyped, from: untyped, to: untyped, within: untyped, ?version_scope: untyped) -> Array[Step]
    def timeline(record, from:, to:, within:, version_scope: nil)
      Endpoint.validate_root!(record)
      ReadSnapshot.call([record]) do
        @traversal_preparer.call(record.class, historical: true)
        from, to = default_range(record, from, to, within)
        TimelineBuilder.new(
          record,
          from: from,
          to: to,
          within: within,
          version_scope: version_scope,
          live_endpoint: live_endpoint_for(record, within),
          snapshotter: @timeline_snapshotter
        ).build
      end
    end

    #: (untyped, from: untyped, to: untyped, within: untyped, ?version_scope: untyped, ?snapshots: bool, ?group: Symbol?) -> Array[ActivityStep]
    def activity_timeline(record, from:, to:, within:, version_scope: nil, snapshots: false, group: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      Endpoint.validate_root!(record)
      payload = model_payload(record)
      Instrumentation.instrument('activity_timeline', payload) do
        steps = ReadSnapshot.call([record]) do
          @traversal_preparer.call(record.class, historical: true)
          from, to = default_range(record, from, to, within)
          live = live_endpoint_for(record, within)
          activity_builder(
            record, from: from, to: to, within: within, version_scope: version_scope,
                    live_endpoint: live, view: activity_view(true, snapshots, group)
          ).build
        end
        payload[:step_count] = steps.length
        steps
      end
    end

    #: (untyped, from: untyped, to: untyped, within: untyped, ?activity: bool, ?version_scope: untyped, ?snapshots: bool, ?group: Symbol?) -> Analysis
    def analyze(record, from:, to:, within:, activity: false, version_scope: nil, snapshots: false, group: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      view = activity_view(activity, snapshots, group)
      Endpoint.validate_root!(record)
      ReadSnapshot.call([record]) do
        analyze_record(record, from: from, to: to, within: within, activity: activity,
                               version_scope: version_scope, view: view)
      end
    end

    # Analyzes many roots over one shared range, preparing their history once.
    #: (Array[untyped], within: untyped, ?activity: bool, ?version_scope: untyped, ?snapshots: bool, ?group: Symbol?) -> Hash[identity, Analysis]
    def analyze_many(records, within:, activity: false, version_scope: nil, snapshots: false, group: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      ReadSnapshot.call(records.is_a?(Array) ? records : []) do
        analyze_batch(records, within: within, activity: activity, version_scope: version_scope,
                               view: activity_view(activity, snapshots, group))
      end
    end

    # Selects the roots from a relation before running the ordinary batch, so a
    # caller reporting on a population does not have to rediscover which of its
    # members changed. The roots the relation could not reach come back named
    # rather than dropped -- see `PaperTrailDiff.analyze_scope`.
    #: (untyped, limit: Integer?, within: untyped, ?activity: bool, ?version_scope: untyped, ?snapshots: bool, ?group: Symbol?, ?historical_filter: untyped, ?max_filter_versions: Integer, ?include_deleted: bool) -> ScopedAnalysis
    def analyze_scope(scope, limit:, within:, activity: false, version_scope: nil, snapshots: false, group: nil, historical_filter: nil, max_filter_versions: HistoricalFilter::DEFAULT_VERSION_LIMIT, include_deleted: false) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      view = activity_view(activity, snapshots, group)
      ReadSnapshot.call([scope]) do
        check_scope(scope)
        scoped_builder(scope, limit: limit, within: within, activity: activity,
                              version_scope: version_scope, historical_filter: historical_filter,
                              max_filter_versions: max_filter_versions,
                              include_deleted: include_deleted, view: view).call
      end
    end

    private

    #: (bool, bool, Symbol?) -> ActivityView
    def activity_view(activity, snapshots, group)
      ActivityView.build(activity: activity, snapshots: snapshots, group: group,
                         recorded: @recorded)
    end

    #: (untyped) -> Hash[Symbol, untyped]
    def model_payload(record)
      @instrumentation_payload.merge(model_type: record.class.base_class.name.to_s)
    end

    #: (untyped, from: untyped, to: untyped, within: untyped, activity: bool, version_scope: untyped, view: ActivityView) -> Analysis
    def analyze_record(record, from:, to:, within:, activity:, version_scope:, view:) # rubocop:disable Metrics/ParameterLists
      @traversal_preparer.call(record.class, historical: true)
      from, to = default_range(record, from, to, within)
      live = live_endpoint_for(record, within)
      builder = if activity
                  activity_builder(
                    record, from: from, to: to, within: within, version_scope: version_scope,
                            live_endpoint: live, view: view
                  )
                else
                  TimelineBuilder.new(
                    record, from: from, to: to, within: within, version_scope: version_scope,
                            live_endpoint: live, snapshotter: @timeline_snapshotter
                  )
                end
      builder.analyze.with_window(builder.window)
    end

    #: (Array[untyped], within: untyped, activity: bool, version_scope: untyped, view: ActivityView) -> Hash[identity, Analysis]
    def analyze_batch(records, within:, activity:, version_scope:, view:)
      count = records.is_a?(Array) ? records.length : 0
      payload = @instrumentation_payload.merge(comparison_count: count)
      Instrumentation.instrument('analyze_many', payload) do
        AnalysisBatch.new(
          records,
          time_range: within.nil? ? nil : TimeRange.new(within), version_scope: version_scope,
          context_required: activity && !@association_tree.empty?,
          live_loader: method(:load_batch_endpoints),
          history_preparer: @historical_store.method(:prepare_batch),
          analyzer: batched_root_analyzer(activity, within: within, view: view)
        ).call
      end
    end

    # Analysis reads association history, so a request it would refuse is
    # refused before the first selection query rather than once analysis starts.
    #: (untyped) -> void
    def check_scope(scope)
      return unless scope.respond_to?(:all) && scope.respond_to?(:where)

      @traversal_preparer.call(scope.all.model, historical: true)
    end

    # The endpoints of the hash comparisons. Anything else is left for the batch to refuse.
    #: (untyped) -> Array[untyped]
    def comparison_endpoints(comparisons)
      return [] unless comparisons.is_a?(Array)

      comparisons.grep(Hash).flat_map(&:values)
    end

    #: (Array[comparison_input], preparer: untyped) -> ComparisonBatch
    def comparison_batch(comparisons, preparer:)
      ComparisonBatch.new(
        comparisons,
        live_loader: @live_endpoints, preparer: preparer,
        history_preparer: @historical_store.method(:prepare_batch),
        version_history_preparer: @historical_store.method(:prepare_deleted_batch),
        historical_snapshotter: method(:historical_snapshot),
        live_normalizer: method(:normalize_live_snapshot)
      )
    end

    # Refused before the current records load, rather than once analysis starts.
    #: (Array[untyped]) -> Hash[identity, untyped]
    def load_batch_endpoints(records)
      records.map(&:class).uniq.each { |model| @traversal_preparer.call(model, historical: true) }
      @live_endpoints.call(records)
    end

    #: (untyped, Array[Array[String]], Hash[Symbol, untyped]) -> Hash[Array[String], Analysis?]
    def analyze_deleted(model, identities, options)
      within = options.fetch(:within)
      analyzer = batched_root_analyzer(options.fetch(:activity), within: within,
                                                                 view: options.fetch(:view))
      DeletedAnalysisBatch.new(
        model, identities: identities, time_range: within.nil? ? nil : TimeRange.new(within),
               version_scope: options.fetch(:version_scope),
               history_preparer: @historical_store.method(:prepare_deleted_batch),
               analyzer: analyzer,
               context_required: options.fetch(:activity) && !@association_tree.empty?
      ).call
    end

    #: (untyped, limit: Integer?, within: untyped, activity: bool, version_scope: untyped, historical_filter: untyped, max_filter_versions: Integer, include_deleted: bool, view: ActivityView) -> ScopedAnalysisBuilder
    def scoped_builder(scope, limit:, within:, activity:, version_scope:, historical_filter:, max_filter_versions:, include_deleted:, view:) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      # @type var options: report_options
      options = { within: within, activity: activity, version_scope: version_scope, view: view }
      ScopedAnalysisBuilder.new(
        scope, limit: limit, within: within, historical_filter: historical_filter,
               max_filter_versions: max_filter_versions, include_deleted: include_deleted,
               analyzer: lambda { |records|
                 analyze_batch(records, within: within, activity: activity,
                                        version_scope: version_scope, view: view)
               },
               deleted_analyzer: lambda { |identities|
                 analyze_deleted(scope.all.model, identities, options)
               },
               # Checkpoints compare a root's own versions, so only activity can
               # report a window in which just its associations changed.
               activity_tree: (@association_tree if activity), version_scope: version_scope
      )
    end

    # @rbs @association_tree: AssociationTree
    # @rbs @live_endpoints: LiveEndpointProvider
    # @rbs @instrumentation_payload: Hash[Symbol, untyped]
    # @rbs @ignore_policy: IgnorePolicy
    # @rbs @recorded: IgnorePolicy?
    # @rbs @traversal: AssociationTraversal
    # @rbs @traversal_preparer: TraversalPreparer
    # @rbs @snapshot_pool: SnapshotPool
    # @rbs @normalizer: SnapshotNormalizer
    # @rbs @historical_store: HistoricalSnapshotStore
    # @rbs @timeline_snapshotter: TimelineSnapshotProvider
    # @rbs @activity_snapshotter: ActivitySnapshotProvider

    # The result may still be correct -- nothing the path reaches may have
    # changed -- and the gem cannot tell which, since not seeing the change is
    # the symptom. So it reports the condition and leaves the judgement to the
    # application.
    #: (untyped, untyped) -> void
    def notify_ambiguous_association_boundary(from_endpoint, to_endpoint)
      return unless ambiguous_association_boundary?(from_endpoint, to_endpoint)

      Instrumentation.notify(
        'ambiguous_association_boundary',
        @instrumentation_payload.merge(
          item_type: from_endpoint.item_type.to_s,
          version_ids: [from_endpoint.id, to_endpoint.id].freeze,
          recorded_at: from_endpoint.created_at
        )
      )
    end

    # Loaded history orders two versions that share a timestamp by id, but
    # PT-AT places association changes by timestamp alone, so only a path it
    # reads can lose a change between them. A request the preparer refuses
    # raises here, before anything is reported.
    #: (untyped, untyped) -> bool
    def ambiguous_association_boundary?(from_endpoint, to_endpoint)
      return false if @association_tree.empty?
      return false unless Endpoint.version?(from_endpoint) && Endpoint.version?(to_endpoint)
      return false unless from_endpoint.created_at == to_endpoint.created_at

      model_class = RecordedClass.for(from_endpoint)
      @traversal_preparer.call(model_class, historical: true)
      FallbackPaths.any?(@traversal, model_class, approximate: true)
    end

    # With neither a window nor endpoints, a range is the record's whole
    # history through its current saved state; a missing endpoint takes that
    # side of the same default.
    #: (untyped, untyped, untyped, untyped) -> [untyped, untyped]
    def default_range(record, from, to, within)
      return [from, to] unless within.nil?

      [from.nil? ? :first : from, to.nil? ? record : to]
    end

    # A window with nothing recorded after its last change ends at the live
    # record, which holds the state that change produced -- whether the window
    # ended a moment ago or long before. Explicit endpoints name their own end.
    # Only a saved row has current state to close on. A destroyed root's own
    # destroy version already terminates its history, and a reified or unsaved
    # instance stands for a state that is not in the table.
    #: (untyped, untyped) -> untyped
    def live_endpoint_for(record, within)
      return if within.nil?
      return unless Endpoint.record?(record) && record.persisted?

      record
    end

    #: () -> void
    def build_snapshotters
      @historical_store = build_historical_store
      @timeline_snapshotter = TimelineSnapshotProvider.new(
        @historical_store, live_snapshotter: method(:live_snapshot)
      )
      @activity_snapshotter = ActivitySnapshotProvider.new(
        store: @historical_store, snapshotter: method(:snapshot_at),
        refresher: method(:branch_refresher)
      )
    end

    #: (bool, within: untyped, view: ActivityView) -> BatchedRootAnalyzer
    def batched_root_analyzer(activity, within:, view:)
      BatchedRootAnalyzer.new(
        tree: @association_tree,
        timeline_snapshotter: @timeline_snapshotter,
        activity_snapshotter: @activity_snapshotter,
        preparer: @traversal_preparer.method(:call),
        activity: activity, within: within, view: view
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

    # Refreshes one root's snapshots, reading with the history prepared for it.
    #: (PreparedActivitySnapshots) -> BranchSnapshotRefresher
    def branch_refresher(snapshots)
      BranchSnapshotRefresher.new(
        tree: @association_tree, ignore_policy: @ignore_policy,
        traversal: @traversal, pool: @snapshot_pool,
        normalizer: @normalizer,
        full_snapshotter: snapshots.method(:call),
        partial_snapshotter: snapshots.method(:custom),
        association_reader: snapshots.method(:association_reader),
        record_transition: snapshots.method(:record_transition),
        prepared_record_after: snapshots.method(:record_after)
      )
    end

    #: (untyped, from: untyped, to: untyped, within: untyped, version_scope: untyped, live_endpoint: untyped, view: ActivityView) -> ActivityTimelineBuilder
    def activity_builder(record, from:, to:, within:, version_scope:, live_endpoint:, view:) # rubocop:disable Metrics/ParameterLists
      ActivityTimelineBuilder.new(
        record,
        range: TimelineRange.new(
          record, from: from, to: to, within: within, version_scope: version_scope,
                  live_endpoint: live_endpoint
        ),
        tree: @association_tree,
        snapshotter: @activity_snapshotter,
        view: view
      )
    end

    #: (untyped) -> RecordSnapshot?
    def snapshot_for_endpoint(endpoint)
      Endpoint.version?(endpoint) ? historical_snapshot(endpoint) : live_snapshot(endpoint)
    end

    #: (untyped) -> RecordSnapshot?
    def historical_snapshot(version)
      snapshot_at(version, version)
    end

    #: (untyped, untyped, ?history: PreparedHistory?) -> RecordSnapshot?
    def snapshot_at(root_endpoint, context_endpoint, history: nil)
      return live_snapshot(root_endpoint) if Endpoint.record?(context_endpoint)

      @historical_store.call(root_endpoint, context_endpoint, history: history)
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
