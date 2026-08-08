# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Optional full/partial snapshot operations consumed by the activity sequence.
  class ActivitySnapshotProvider
    #: (snapshotter: untyped, refresher: untyped) -> void
    def initialize(snapshotter:, refresher:)
      @snapshotter = snapshotter
      @refresher = refresher
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def call(root_endpoint, context_endpoint)
      @snapshotter.call(root_endpoint, context_endpoint)
    end

    #: (untyped, untyped, RecordSnapshot?, Array[String]) -> RecordSnapshot?
    def refresh(root_endpoint, context_endpoint, previous_snapshot, branches)
      @refresher.call(root_endpoint, context_endpoint, previous_snapshot, branches)
    end

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
    end

    #: () -> Array[RecordSnapshot?]
    def call
      first = @events.first
      return [] unless first

      snapshots = [full_snapshot(first)]
      @events.each_cons(2) do |pair|
        previous_event = pair.fetch(0)
        event = pair.fetch(1)
        snapshots << transition_snapshot(previous_event, event, snapshots.last)
      end
      snapshots
    end

    private

    # @rbs @root_versions: Array[untyped]
    # @rbs @events: Array[ActivityEvent]
    # @rbs @snapshotter: untyped
    # @rbs @current: untyped
    # @rbs @transaction_groups: ActivityTransactionGroups

    #: (ActivityEvent, ActivityEvent, RecordSnapshot?) -> RecordSnapshot?
    def transition_snapshot(previous_event, event, previous_snapshot)
      branches = @transaction_groups.branches_for(previous_event)
      return full_snapshot(event) unless branches && @snapshotter.respond_to?(:refresh)

      @snapshotter.refresh(
        root_endpoint(event.version),
        event.version,
        previous_snapshot,
        branches
      )
    end

    #: (ActivityEvent) -> RecordSnapshot?
    def full_snapshot(event)
      @snapshotter.call(root_endpoint(event.version), event.version)
    end

    #: (untyped) -> untyped
    def root_endpoint(activity_version)
      root_anchor(activity_version) || @current || @root_versions.last
    end

    #: (untyped) -> untyped
    def root_anchor(activity_version)
      @root_versions.find do |root_version|
        Support.compare_versions(root_version, activity_version) >= 0
      end
    end
  end
end
