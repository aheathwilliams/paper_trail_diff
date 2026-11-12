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
    # What credits the rows of a step `last_boundary` opens.
    attr_reader :last_attribution #: ChangeAttribution?

    #: (steps: Array[ActivityStep], root_snapshots: Hash[Array[untyped], RecordSnapshot?], first_snapshot: RecordSnapshot?, last_snapshot: RecordSnapshot?, ?last_boundary: ActivityBoundary?, ?last_event_snapshot: RecordSnapshot?, ?last_event: ActivityEvent?, ?last_attribution: ChangeAttribution?) -> void
    def initialize(steps:, root_snapshots:, first_snapshot:, last_snapshot:, last_boundary: nil, last_event_snapshot: nil, last_event: nil, last_attribution: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      @steps = steps.freeze
      @root_snapshots = root_snapshots.freeze
      @first_snapshot = first_snapshot
      @last_snapshot = last_snapshot
      @last_boundary = last_boundary
      @last_event_snapshot = last_event_snapshot
      @last_event = last_event
      @last_attribution = last_attribution
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
    # `include_step` says whether an event's step is reported. `root` names
    # the root, whose steps credit each change row to the version that made
    # it (see ChangeAttribution).
    #: (Array[untyped], Array[ActivityEvent], untyped, view: ActivityView, include_step: untyped, ?current: untyped, ?closing: RecordSnapshot?, root: RecordReference) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      root_versions, events, snapshotter,
      view:, include_step:, root:, current: nil, closing: nil
    )
      @root_versions = root_versions
      @events = events
      @snapshotter = snapshotter
      @view = view
      @current = current
      @include_step = include_step
      @closing = closing
      @root = root
      # A builder makes one pass; the rest of its state starts out nil.
      @steps = []
      @root_snapshots = {}
      @transactions = {}
      @first_pending = true
    end

    #: () -> ActivityHistory
    def call
      filter.call(sequence) { |event, snapshot, kept| consume(event, snapshot, kept) }
      ActivityHistory.new(
        steps: @steps,
        root_snapshots: @root_snapshots,
        first_snapshot: @first_snapshot,
        last_snapshot: @selected_last_snapshot,
        last_boundary: @previous_boundary,
        last_event_snapshot: @previous_snapshot,
        last_event: @previous_event,
        last_attribution: @previous_attribution
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
    # @rbs @previous_attribution: ChangeAttribution?
    # @rbs @passed_reported: bool?
    # @rbs @root: RecordReference
    # @rbs @transactions: Hash[Array[untyped], ChangeAttribution::Transaction]

    #: () -> ActivityTreeFilter
    def filter
      ActivityTreeFilter.new(@events, closing: @closing)
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
    # events left out before it are of records outside the root's tree, and
    # change nothing the root shows (see ActivityTreeFilter). And a version
    # filter starts it at the first change it keeps.
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
      @previous_attribution = attribution(event, boundary)
    end

    # Inside a transaction a record's change can surface at a later event
    # than its own, so the rows of a step its boundary opens are read with
    # the boundaries its transaction kept before it (see ChangeAttribution).
    #: (ActivityEvent, ActivityBoundary) -> ChangeAttribution
    def attribution(event, boundary)
      transaction = transaction_of(event)
      attribution = ChangeAttribution.new(root: @root, sources: [boundary],
                                          transaction: transaction)
      transaction.add(boundary)
      attribution
    end

    # The boundaries kept so far of the event's transaction. A version saved
    # outside a transaction is a transaction of its own.
    #: (ActivityEvent) -> ChangeAttribution::Transaction
    def transaction_of(event)
      key = ActivityTransactionGroups.transaction_key(event.version)
      return ChangeAttribution::Transaction.new unless key

      @transactions[key] ||= ChangeAttribution::Transaction.new
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
        from_snapshot: @previous_snapshot, to_snapshot: snapshot, retain: @view.retain?,
        attribution: @previous_attribution
      )
      @selected_last_snapshot = snapshot
    end
  end
end
