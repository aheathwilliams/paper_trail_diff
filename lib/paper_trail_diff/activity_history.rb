# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Immutable snapshots and steps produced by one activity-history pass.
  class ActivityHistory
    attr_reader :steps #: Array[ActivityStep]
    attr_reader :root_snapshots #: Hash[Array[untyped], RecordSnapshot?]
    attr_reader :first_snapshot #: RecordSnapshot?
    attr_reader :last_snapshot #: RecordSnapshot?

    #: (steps: Array[ActivityStep], root_snapshots: Hash[Array[untyped], RecordSnapshot?], first_snapshot: RecordSnapshot?, last_snapshot: RecordSnapshot?) -> void
    def initialize(steps:, root_snapshots:, first_snapshot:, last_snapshot:)
      @steps = steps.freeze
      @root_snapshots = root_snapshots.freeze
      @first_snapshot = first_snapshot
      @last_snapshot = last_snapshot
      freeze
    end

    #: () -> ActivityHistory
    def self.empty
      new(steps: [], root_snapshots: {}, first_snapshot: nil, last_snapshot: nil)
    end
  end

  # Builds activity steps while retaining root snapshots for combined analysis.
  class ActivityHistoryBuilder
    #: (Array[untyped], Array[ActivityEvent], untyped, ?current: untyped, ?include_step: untyped) -> void
    def initialize(root_versions, events, snapshotter, current: nil, include_step: nil)
      @root_versions = root_versions
      @events = events
      @snapshotter = snapshotter
      @current = current
      @include_step = include_step
    end

    #: () -> ActivityHistory
    def call
      reset
      sequence.each { |event, snapshot| consume(event, snapshot) }
      ActivityHistory.new(
        steps: @steps,
        root_snapshots: @root_snapshots,
        first_snapshot: @first_snapshot,
        last_snapshot: final_snapshot
      )
    end

    private

    # @rbs @root_versions: Array[untyped]
    # @rbs @events: Array[ActivityEvent]
    # @rbs @snapshotter: untyped
    # @rbs @current: untyped
    # @rbs @include_step: untyped
    # @rbs @steps: Array[ActivityStep]
    # @rbs @root_snapshots: Hash[Array[untyped], RecordSnapshot?]
    # @rbs @first_snapshot: RecordSnapshot?
    # @rbs @previous_snapshot: RecordSnapshot?
    # @rbs @selected_last_snapshot: RecordSnapshot?
    # @rbs @previous_boundary: ActivityBoundary?
    # @rbs @previous_event: ActivityEvent?

    #: () -> void
    def reset
      @steps = []
      @root_snapshots = {}
      @first_snapshot = nil
      @first_snapshot_seen = false
      @previous_snapshot = nil
      @selected_last_snapshot = nil
      @previous_boundary = nil
      @previous_event = nil
    end

    #: () -> ActivitySnapshotSequence
    def sequence
      ActivitySnapshotSequence.new(
        @root_versions,
        @events,
        @snapshotter,
        current: @current
      )
    end

    #: (ActivityEvent, RecordSnapshot?) -> void
    def consume(event, snapshot)
      capture_first(snapshot)
      boundary = ActivityBoundary.from_version(event.version)
      @root_snapshots[version_key(event.version)] = snapshot if event.root?
      append_step(boundary, snapshot) if @previous_boundary
      @previous_boundary = boundary
      @previous_event = event
      @previous_snapshot = snapshot
    end

    #: (RecordSnapshot?) -> void
    def capture_first(snapshot)
      return if @first_snapshot_seen

      @first_snapshot = snapshot
      @first_snapshot_seen = true
    end

    #: (ActivityBoundary, RecordSnapshot?) -> void
    def append_step(boundary, snapshot)
      return unless include_previous_step?

      previous_boundary = @previous_boundary
      return unless previous_boundary

      @steps << ActivityStep.new(
        from_boundary: previous_boundary,
        to_boundary: boundary,
        diff: Engine.compare(@previous_snapshot, snapshot)
      )
      @selected_last_snapshot = snapshot
    end

    #: () -> bool
    def include_previous_step?
      !@include_step || @include_step.call(@previous_event)
    end

    #: () -> RecordSnapshot?
    def final_snapshot
      @include_step ? @selected_last_snapshot : @previous_snapshot
    end

    #: (untyped) -> Array[untyped]
    def version_key(version)
      [version.class.name, version.id]
    end
  end
end
