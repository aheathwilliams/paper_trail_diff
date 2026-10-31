# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Prepares the snapshot store for an activity build, one root at a time.
  # Before that, it reads the live record a range closes on.
  class ActivitySnapshotProvider
    # `snapshotter` reads a full snapshot with a given history, and `refresher`
    # builds the incremental refresher for one root's snapshots.
    #: (store: HistoricalSnapshotStore, snapshotter: untyped, refresher: untyped) -> void
    def initialize(store:, snapshotter:, refresher:)
      @store = store
      @snapshotter = snapshotter
      @refresher = refresher
    end

    # Roots a batch prepared together share its history, so consecutive ones
    # share these snapshots too, and the caches their refresher builds. They
    # are the same for any root with that history, so reusing them depends on
    # nothing but the history.
    #: (untyped, Array[untyped], ?start_at: untyped, ?end_at: untyped) -> PreparedActivitySnapshots
    def prepare(
      record,
      root_versions,
      start_at: root_versions.first.created_at,
      end_at: root_versions.last.created_at
    )
      history = @store.prepare(record, root_versions, start_at: start_at, end_at: end_at)
      last = @last
      return last if last && last.history.equal?(history)

      @last = PreparedActivitySnapshots.new(history, store: @store, snapshotter: @snapshotter,
                                                     refresher: @refresher)
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def call(root_endpoint, context_endpoint)
      @snapshotter.call(root_endpoint, context_endpoint)
    end

    # @rbs @store: HistoricalSnapshotStore
    # @rbs @snapshotter: untyped
    # @rbs @refresher: untyped
    # @rbs @last: PreparedActivitySnapshots?
  end

  # One root's full and incremental snapshots during an activity build. Each
  # read passes along the history prepared for this root, so none depends on
  # which root was prepared last.
  class PreparedActivitySnapshots
    attr_reader :history #: PreparedHistory?

    #: (PreparedHistory?, store: HistoricalSnapshotStore, snapshotter: untyped, refresher: untyped) -> void
    def initialize(history, store:, snapshotter:, refresher:)
      @history = history
      @store = store
      @snapshotter = snapshotter
      @refresher = refresher.call(self)
    end

    #: () -> PreparedActivityIndex?
    def activity_index
      @history&.activity_index
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def call(root_endpoint, context_endpoint)
      @snapshotter.call(root_endpoint, context_endpoint, history: @history)
    end

    #: (untyped, untyped, RecordSnapshot?, Array[String], event: ActivityEvent, isolated: bool) -> RecordSnapshot?
    def refresh(root_endpoint, context_endpoint, previous_snapshot, branches, event:, isolated:) # rubocop:disable Metrics/ParameterLists
      @refresher.call(root_endpoint, context_endpoint, previous_snapshot, branches,
                      event: event, isolated: isolated)
    end

    #: (untyped, untyped, RecordSnapshot?, event: ActivityEvent) -> RecordSnapshot?
    def advance_root(root_endpoint, context_endpoint, previous_snapshot, event:)
      @refresher.advance_root(root_endpoint, context_endpoint, previous_snapshot, event: event)
    end

    # The branches a refresh rebuilds, with this root's history.
    #: (untyped, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer) -> RecordSnapshot?
    def custom(root_endpoint, context_endpoint, tree:, normalizer:)
      @store.custom(root_endpoint, context_endpoint, tree: tree, normalizer: normalizer,
                                                     history: @history)
    end

    #: (untyped, habtm_version: untyped) -> untyped
    def association_reader(context_version, habtm_version:)
      @store.association_reader(context_version, habtm_version: habtm_version, history: @history)
    end

    #: (untyped) -> [Hash[untyped, untyped], Hash[untyped, untyped]]?
    def record_transition(version)
      @history&.record_transition(Endpoint.model_class(version), version.item_id, version)
    end

    #: (untyped, ?direct: bool) -> [bool, untyped]
    def record_after(version, direct: false)
      @history&.record_after(Endpoint.model_class(version), version.item_id, version,
                             direct: direct) || [false, nil]
    end

    # @rbs @store: HistoricalSnapshotStore
    # @rbs @snapshotter: untyped
    # @rbs @refresher: untyped
  end

  # Builds chronological snapshots, refreshing only branches affected by prior events.
  class ActivitySnapshotSequence
    #: (Array[untyped], Array[ActivityEvent], untyped, ?current: untyped) -> void
    def initialize(root_versions, events, snapshotter, current: nil)
      @root_versions = root_versions
      @events = events
      @snapshotter = snapshotter
      @current = current
      @transaction_groups = ActivityTransactionGroups.new(events)
      @root_endpoints = build_root_endpoints
    end

    #: () -> Array[RecordSnapshot?]
    def call
      snapshots = [] #: Array[RecordSnapshot?]
      each { |_event, snapshot| snapshots << snapshot }
      snapshots
    end

    #: () { (ActivityEvent, RecordSnapshot?) -> void } -> void
    def each
      first = @events.first
      return unless first

      previous_snapshot = full_snapshot(first)
      yield first, previous_snapshot
      @events.each_cons(2) do |pair|
        previous_event = pair.fetch(0)
        event = pair.fetch(1)
        previous_snapshot = transition_snapshot(previous_event, event, previous_snapshot)
        yield event, previous_snapshot
      end
    end

    private

    # @rbs @root_versions: Array[untyped]
    # @rbs @events: Array[ActivityEvent]
    # @rbs @snapshotter: untyped
    # @rbs @current: untyped
    # @rbs @transaction_groups: ActivityTransactionGroups
    # @rbs @root_endpoints: Hash[untyped, untyped]

    #: (ActivityEvent, ActivityEvent, RecordSnapshot?) -> RecordSnapshot?
    def transition_snapshot(previous_event, event, previous_snapshot)
      return advance_root(previous_event, event, previous_snapshot) if
        incremental_root?(previous_event)

      branches = @transaction_groups.branches_for(previous_event)
      return full_snapshot(event) unless branches

      @snapshotter.refresh(
        root_endpoint(event.version),
        event.version,
        previous_snapshot,
        branches,
        event: previous_event,
        isolated: @transaction_groups.isolated?(previous_event)
      )
    end

    #: (ActivityEvent) -> bool
    def incremental_root?(event)
      event.root? && @transaction_groups.isolated?(event)
    end

    #: (ActivityEvent, ActivityEvent, RecordSnapshot?) -> RecordSnapshot?
    def advance_root(previous_event, event, previous_snapshot)
      @snapshotter.advance_root(
        root_endpoint(event.version),
        event.version,
        previous_snapshot,
        event: previous_event
      )
    end

    #: (ActivityEvent) -> RecordSnapshot?
    def full_snapshot(event)
      @snapshotter.call(root_endpoint(event.version), event.version)
    end

    #: (untyped) -> untyped
    def root_endpoint(activity_version)
      @root_endpoints.fetch(activity_version)
    end

    #: () -> Hash[untyped, untyped]
    def build_root_endpoints
      root_index = 0
      endpoints = {} #: Hash[untyped, untyped]
      endpoints.compare_by_identity
      @events.each do |event|
        while @root_versions[root_index] &&
              Support.compare_versions(@root_versions[root_index], event.version).negative?
          root_index += 1
        end
        endpoint = @root_versions[root_index] || @current || @root_versions.last
        endpoints[event.version] = endpoint
      end
      endpoints
    end
  end
end
