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
    # The event of `last_boundary`.
    attr_reader :last_event #: ActivityEvent?

    #: (steps: Array[ActivityStep], root_snapshots: Hash[Array[untyped], RecordSnapshot?], first_snapshot: RecordSnapshot?, last_snapshot: RecordSnapshot?, ?last_boundary: ActivityBoundary?, ?last_event_snapshot: RecordSnapshot?, ?last_event: ActivityEvent?) -> void
    def initialize(steps:, root_snapshots:, first_snapshot:, last_snapshot:, last_boundary: nil, last_event_snapshot: nil, last_event: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      @steps = steps.freeze
      @root_snapshots = root_snapshots.freeze
      @first_snapshot = first_snapshot
      @last_snapshot = last_snapshot
      @last_boundary = last_boundary
      @last_event_snapshot = last_event_snapshot
      @last_event = last_event
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
    # `include_step` says whether an event's step is reported.
    #: (Array[untyped], Array[ActivityEvent], untyped, view: ActivityView, include_step: untyped, ?current: untyped, ?closing: RecordSnapshot?) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      root_versions, events, snapshotter, view:, include_step:, current: nil, closing: nil
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
        last_snapshot: @selected_last_snapshot,
        last_boundary: @previous_boundary,
        last_event_snapshot: @previous_snapshot,
        last_event: @previous_event
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
    # @rbs @first_pending: bool
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
      @first_pending = true
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
    #
    # The history starts at the first kept event whose step is reported. The
    # events left out before it change nothing the root shows, unless they are
    # of a transaction that crossed the window's start and has no event kept
    # here: the snapshot at them is the state before that transaction, whose
    # changes the window before this one reports (see ActivityTreeFilter). And
    # a version filter starts it at the first change it keeps.
    #: (ActivityEvent, RecordSnapshot?, bool) -> void
    def consume(event, snapshot, kept)
      return pass(event) unless kept

      capture_first(event, snapshot)
      boundary = ActivityBoundary.from_version(
        event.version, recorded: @view.recorded_reader(root: event.root?)
      )
      @root_snapshots[Support.row_key(event.version)] = snapshot if event.root?
      append_step(boundary, snapshot) if @previous_boundary
      @selected_last_snapshot = snapshot if @passed_reported
      @passed_reported = false
      @previous_boundary = boundary
      @previous_event = event
      @previous_snapshot = snapshot
    end

    #: (ActivityEvent) -> void
    def pass(event)
      @passed_reported = true if reported?(event)
    end

    #: (ActivityEvent, RecordSnapshot?) -> void
    def capture_first(event, snapshot)
      return unless @first_pending && reported?(event)

      @first_snapshot = snapshot
      @first_pending = false
    end

    #: (ActivityEvent) -> bool
    def reported?(event)
      @include_step.call(event)
    end

    # The step from the previous boundary, which `consume` has, to this one.
    #: (ActivityBoundary, RecordSnapshot?) -> void
    def append_step(boundary, snapshot)
      previous_boundary = @previous_boundary #: ActivityBoundary
      previous_event = @previous_event #: ActivityEvent
      return unless reported?(previous_event)

      @steps << ActivityStep.between(
        from_boundary: previous_boundary, to_boundary: boundary,
        from_snapshot: @previous_snapshot, to_snapshot: snapshot, retain: @view.retain?
      )
      @selected_last_snapshot = snapshot
    end
  end
end
