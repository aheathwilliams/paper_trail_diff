# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Immutable snapshots and steps produced by one activity-history pass.
  class ActivityHistory
    attr_reader :steps #: Array[ActivityStep]
    attr_reader :root_snapshots #: Hash[Array[untyped], RecordSnapshot?]
    attr_reader :first_snapshot #: RecordSnapshot?
    attr_reader :last_snapshot #: RecordSnapshot?
    attr_reader :last_boundary #: ActivityBoundary?
    attr_reader :last_event_snapshot #: RecordSnapshot?

    #: (steps: Array[ActivityStep], root_snapshots: Hash[Array[untyped], RecordSnapshot?], first_snapshot: RecordSnapshot?, last_snapshot: RecordSnapshot?, ?last_boundary: ActivityBoundary?, ?last_event_snapshot: RecordSnapshot?) -> void
    def initialize(steps:, root_snapshots:, first_snapshot:, last_snapshot:, last_boundary: nil, last_event_snapshot: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      @steps = steps.freeze
      @root_snapshots = root_snapshots.freeze
      @first_snapshot = first_snapshot
      @last_snapshot = last_snapshot
      @last_boundary = last_boundary
      @last_event_snapshot = last_event_snapshot
      freeze
    end

    #: () -> ActivityHistory
    def self.empty
      new(steps: [], root_snapshots: {}, first_snapshot: nil, last_snapshot: nil)
    end
  end

  # Builds activity steps while retaining root snapshots for combined analysis.
  class ActivityHistoryBuilder
    # `closing` is the snapshot after the last event when the range closes on
    # the current record. Any other range ends at a root event, or at events
    # after a window whose steps are not reported, so nothing reads it.
    #: (Array[untyped], Array[ActivityEvent], untyped, view: ActivityView, ?current: untyped, ?include_step: untyped, ?closing: RecordSnapshot?) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      root_versions, events, snapshotter, view:, current: nil, include_step: nil, closing: nil
    )
      @root_versions = root_versions
      @events = events
      @snapshotter = snapshotter
      @view = view
      @current = current
      @include_step = include_step
      @closing = closing
    end

    #: () -> ActivityHistory
    def call
      reset
      filter.call(sequence) { |event, snapshot, kept| consume(event, snapshot, kept) }
      ActivityHistory.new(
        steps: @steps,
        root_snapshots: @root_snapshots,
        first_snapshot: @first_snapshot,
        last_snapshot: final_snapshot,
        last_boundary: @previous_boundary,
        last_event_snapshot: @previous_snapshot
      )
    end

    private

    # @rbs @root_versions: Array[untyped]
    # @rbs @events: Array[ActivityEvent]
    # @rbs @snapshotter: untyped
    # @rbs @current: untyped
    # @rbs @include_step: untyped
    # @rbs @view: ActivityView
    # @rbs @closing: RecordSnapshot?
    # @rbs @steps: Array[ActivityStep]
    # @rbs @root_snapshots: Hash[Array[untyped], RecordSnapshot?]
    # @rbs @first_snapshot: RecordSnapshot?
    # @rbs @previous_snapshot: RecordSnapshot?
    # @rbs @selected_last_snapshot: RecordSnapshot?
    # @rbs @previous_boundary: ActivityBoundary?
    # @rbs @previous_event: ActivityEvent?
    # @rbs @passed_reported: bool

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
      @passed_reported = false
    end

    #: () -> ActivityTreeFilter
    def filter
      ActivityTreeFilter.new(@events, reported: @include_step, closing: @closing)
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

    # A left-out event bounds nothing. A reported step it would have opened
    # still moves the reported range's end past it, to the next boundary.
    #: (ActivityEvent, RecordSnapshot?, bool) -> void
    def consume(event, snapshot, kept)
      capture_first(snapshot)
      return pass(event) unless kept

      boundary = ActivityBoundary.from_version(
        event.version, recorded: @view.recorded_attributes(root: event.root?)
      )
      @root_snapshots[version_key(event.version)] = snapshot if event.root?
      append_step(boundary, snapshot) if @previous_boundary
      @selected_last_snapshot = snapshot if @passed_reported
      @passed_reported = false
      @previous_boundary = boundary
      @previous_event = event
      @previous_snapshot = snapshot
    end

    #: (ActivityEvent) -> void
    def pass(event)
      @passed_reported = true if !@include_step || @include_step.call(event)
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

      @steps << ActivityStep.between(
        from_boundary: previous_boundary, to_boundary: boundary,
        from_snapshot: @previous_snapshot, to_snapshot: snapshot, retain: @view.retain?
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
