# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Optional full/partial snapshot operations consumed by the activity sequence.
  class ActivitySnapshotProvider
    #: (snapshotter: untyped, refresher: untyped, preparer: untyped) -> void
    def initialize(snapshotter:, refresher:, preparer:)
      @snapshotter = snapshotter
      @refresher = refresher
      @preparer = preparer
    end

    #: (untyped, Array[untyped]) -> void
    def prepare(record, root_versions)
      @preparer.call(record, root_versions)
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def call(root_endpoint, context_endpoint)
      @snapshotter.call(root_endpoint, context_endpoint)
    end

    #: (untyped, untyped, RecordSnapshot?, Array[String], event: ActivityEvent, isolated: bool) -> RecordSnapshot?
    def refresh( # rubocop:disable Metrics/ParameterLists
      root_endpoint,
      context_endpoint,
      previous_snapshot,
      branches,
      event:,
      isolated:
    )
      @refresher.call(
        root_endpoint,
        context_endpoint,
        previous_snapshot,
        branches,
        event: event,
        isolated: isolated
      )
    end

    #: (untyped, untyped, RecordSnapshot?, event: ActivityEvent) -> RecordSnapshot?
    def advance_root(root_endpoint, context_endpoint, previous_snapshot, event:)
      @refresher.advance_root(
        root_endpoint,
        context_endpoint,
        previous_snapshot,
        event: event
      )
    end

    # @rbs @snapshotter: untyped
    # @rbs @refresher: untyped
    # @rbs @preparer: untyped
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
      return full_snapshot(event) unless branches && @snapshotter.respond_to?(:refresh)

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
      event.root? && @transaction_groups.isolated?(event) &&
        @snapshotter.respond_to?(:advance_root)
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
