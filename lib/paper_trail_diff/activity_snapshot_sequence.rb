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
    #
    # A `start_at` is a window's; a range of versions starts at its first.
    #: (untyped, Array[untyped], ?start_at: untyped, ?end_at: untyped) -> PreparedActivitySnapshots
    def prepare(record, root_versions, start_at: nil, end_at: nil)
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

    # See HistoricalSnapshotStore#range_end_of.
    #: (untyped, untyped) -> untyped
    def range_end(record, version) = @store.range_end_of(record, version)

    # See HistoricalSnapshotStore#reach_before.
    #: (untyped, untyped) -> untyped
    def reach_before(record, start_at) = @store.reach_before(record, start_at)

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

    # Reads with where each transaction of a root's timeline takes effect
    # (see TransactionEnds).
    #: (TransactionEnds) { () -> void } -> void
    def reading(ends, &block)
      history = @history
      history ? history.reading(ends, &block) : yield
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

    #: (untyped, untyped, RecordSnapshot, Array[String]?, Array[ActivityEvent]) -> RecordSnapshot?
    def apply_transaction(root_endpoint, context_endpoint, previous_snapshot, branches, events)
      @refresher.apply_transaction(root_endpoint, context_endpoint, previous_snapshot, branches,
                                   events)
    end

    # The branches a refresh rebuilds, with this root's history.
    #: (untyped, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer) -> RecordSnapshot?
    def custom(root_endpoint, context_endpoint, tree:, normalizer:)
      @store.custom(root_endpoint, context_endpoint, tree: tree, normalizer: normalizer,
                                                     history: @history)
    end

    # The state this root's snapshot at an endpoint is built from, where
    # prepared history builds it.
    #: (untyped) -> PreparedRecordState?
    def root_state(root_endpoint)
      @store.root_state(root_endpoint) if @history
    end

    #: (untyped) -> untyped
    def association_reader(context_version)
      @store.association_reader(context_version, history: @history)
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
    # `ends` places the events' transactions, as the events were ordered by.
    #: (Array[untyped], Array[ActivityEvent], untyped, ends: TransactionEnds, ?current: untyped) -> void
    def initialize(root_versions, events, snapshotter, ends:, current: nil)
      @root_versions = root_versions
      @events = events
      @snapshotter = snapshotter
      @current = current
      @ends = ends
      @transaction_groups = ActivityTransactionGroups.new(events)
      @root_endpoints = build_root_endpoints
    end

    #: () { (ActivityEvent, RecordSnapshot?) -> void } -> void
    def each(&block)
      first = @events.first
      return unless first

      @snapshotter.reading(@ends) { replay(first, &block) }
    end

    private

    #: (ActivityEvent) { (ActivityEvent, RecordSnapshot?) -> void } -> void
    def replay(first)
      previous_snapshot = full_snapshot(first)
      yield first, previous_snapshot
      @events.each_cons(2) do |pair|
        previous_event = pair.fetch(0)
        event = pair.fetch(1)
        previous_snapshot = transition_snapshot(previous_event, event, previous_snapshot)
        yield event, previous_snapshot
      end
    end

    # @rbs @root_versions: Array[untyped]
    # @rbs @events: Array[ActivityEvent]
    # @rbs @snapshotter: untyped
    # @rbs @current: untyped
    # @rbs @ends: TransactionEnds
    # @rbs @transaction_groups: ActivityTransactionGroups
    # @rbs @root_endpoints: Hash[untyped, untyped]

    #: (ActivityEvent, ActivityEvent, RecordSnapshot?) -> RecordSnapshot?
    def transition_snapshot(previous_event, event, previous_snapshot)
      return advance_root(previous_event, event, previous_snapshot) if
        incremental_root?(previous_event)

      branches = @transaction_groups.branches_for(previous_event)
      return rebuilt_snapshot(previous_event, event, previous_snapshot) unless branches
      return transaction_snapshot(previous_event, event, previous_snapshot, branches) if
        previous_snapshot && !@transaction_groups.isolated?(previous_event)

      @snapshotter.refresh(
        root_endpoint(event.version),
        event.version,
        previous_snapshot,
        branches,
        event: previous_event,
        isolated: @transaction_groups.isolated?(previous_event)
      )
    end

    # A transaction that saved several records is read whole once it ends:
    # until then the records it saved read as they stood before it began, so
    # the snapshot is the same from one of its events to the next. At the
    # event after its last, each of its versions is applied to the record it
    # saved, rather than reading their branches again, which costs every
    # record in them. `branches` are those of a transaction without a root
    # event, and nil for one with.
    #: (ActivityEvent, ActivityEvent, RecordSnapshot, Array[String]?) -> RecordSnapshot?
    def transaction_snapshot(previous_event, event, previous_snapshot, branches)
      return previous_snapshot if branches && @transaction_groups.shared?(previous_event, event)

      @snapshotter.apply_transaction(
        root_endpoint(event.version), event.version, previous_snapshot, branches,
        @transaction_groups.events_for(previous_event)
      )
    end

    # A transaction with a root event is read whole once it ends. Until then,
    # PT-AT reads the records it saved as they stood before it began, so from
    # one descendant's event to the next in the same transaction the snapshot
    # is the same, and from the root's event to a descendant's only the root's
    # own version applies, as when it is alone in its transaction. A create
    # leaves nothing to advance. The root's version can record what the
    # transaction changed, such as HABTM membership, so at a root event those
    # branches are read again. At the event after the transaction's last,
    # each of its versions is applied to the record it saved.
    #: (ActivityEvent, ActivityEvent, RecordSnapshot?) -> RecordSnapshot?
    def rebuilt_snapshot(previous_event, event, previous_snapshot)
      return full_snapshot(event) unless previous_snapshot
      return transaction_snapshot(previous_event, event, previous_snapshot, nil) unless
        @transaction_groups.shared?(previous_event, event)
      return within_transaction(previous_event, event, previous_snapshot) if previous_event.root?

      event.root? ? carried_snapshot(event, previous_snapshot) : previous_snapshot
    end

    # From the root's event to the next in its transaction: a second version
    # of the root is read again, and a descendant's event takes only the
    # root's own version.
    #: (ActivityEvent, ActivityEvent, RecordSnapshot) -> RecordSnapshot?
    def within_transaction(previous_event, event, previous_snapshot)
      return full_snapshot(event) if event.root?

      advance_root(previous_event, event, previous_snapshot)
    end

    # The snapshot at a root's event, from the one at a descendant's event
    # before it in its transaction: the same, but for the branches the
    # root's version itself records.
    #: (ActivityEvent, RecordSnapshot) -> RecordSnapshot?
    def carried_snapshot(event, previous_snapshot)
      branches = [] #: Array[String]
      events = [] #: Array[ActivityEvent]
      @snapshotter.apply_transaction(root_endpoint(event.version), event.version,
                                     previous_snapshot, branches, events)
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
        placed = @ends.sort_key(event.version)
        while @root_versions[root_index] &&
              (@ends.sort_key(@root_versions[root_index]) <=> placed) == -1
          root_index += 1
        end
        endpoint = @root_versions[root_index] || @current || @root_versions.last
        endpoints[event.version] = endpoint
      end
      endpoints
    end
  end
end
