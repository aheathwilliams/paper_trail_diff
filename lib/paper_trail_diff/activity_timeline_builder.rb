# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Compares adjacent root and selected-descendant activity boundaries, between
  # explicit endpoints or over a wall-clock window. Both replay the range's
  # events into steps the same way, and close on the live row the same way.
  # They differ in what they report and what closes them: explicit endpoints
  # report every step between them and close on the endpoint asked for; a
  # window reports only the events inside it, and closes on a final destroy,
  # or on the live row when nothing recorded follows it.
  class ActivityTimelineBuilder # rubocop:disable Metrics/ClassLength
    #: (untyped, range: TimelineRange, tree: AssociationTree, snapshotter: untyped, view: ActivityView) -> void
    def initialize(record, range:, tree:, snapshotter:, view:)
      @view = view
      @record = record
      @to = range.to
      @range = range
      @tree = tree
      @snapshotter = snapshotter
      # The root's own activity reads a version filter's answers from the plan.
      @filter = (view.version_filter unless tree.empty?)
    end

    #: () -> Array[ActivityStep]
    def build
      return steps_of(window_replay) if @range.time?
      return no_steps if @range.unresolved?
      return steps_of(current_replay) if Endpoint.record?(@to)

      Endpoint.validate!(@to)
      steps_of(version_replay)
    end

    # The window the range covers once its edges have moved to transactions.
    #: () -> TimeRange?
    def window
      @range.time_range
    end

    # Builds the endpoint diff, the root timeline, and the activity from one
    # activity snapshot pass.
    #: () -> Analysis
    def analyze
      return analysis(window_replay) if @range.time?
      return Analysis.empty if @range.unresolved?
      return analysis(current_replay) if Endpoint.record?(@to)

      analysis(version_replay)
    end

    private

    # @rbs @record: untyped
    # @rbs @to: untyped
    # @rbs @range: TimelineRange
    # @rbs @tree: AssociationTree
    # @rbs @snapshotter: untyped
    # @rbs @view: ActivityView
    # @rbs @filter: ActivityScopeFilter?

    #: () -> Array[ActivityStep]
    def no_steps
      steps = [] #: Array[ActivityStep]
      steps.freeze
    end

    # Each kind of range replays into the same things, or into nil when it
    # reports no step: its plan and history, the steps it reports, ending with
    # the one that closes the range after its last event, the state it ends
    # at, and the live record's snapshot and when it was read, which the root
    # timeline's closing step reads.
    #: (RootVersionPlan, ActivityHistory, ActivityStep?, RecordSnapshot?, ?RecordSnapshot?, ?untyped) -> [RootVersionPlan, ActivityHistory, Array[ActivityStep], RecordSnapshot?, RecordSnapshot?, untyped]?
    def replayed(plan, history, closing, final, snapshot = nil, captured_at = nil) # rubocop:disable Metrics/ParameterLists
      steps = closing ? history.steps + [closing] : history.steps
      [plan, history, steps, final, snapshot, captured_at] unless steps.empty?
    end

    #: ([RootVersionPlan, ActivityHistory, Array[ActivityStep], RecordSnapshot?, RecordSnapshot?, untyped]?) -> Array[ActivityStep]
    def steps_of(replay)
      replay ? present(replay.fetch(2)) : no_steps
    end

    # A range that reports no step is empty, whatever its replay read: a
    # version filter may keep nothing in it, or only the version that ends it,
    # which opens no step, and a range may run from a version to itself.
    #: ([RootVersionPlan, ActivityHistory, Array[ActivityStep], RecordSnapshot?, RecordSnapshot?, untyped]?) -> Analysis
    def analysis(replay)
      return Analysis.empty unless replay

      plan, history, steps, final, snapshot, captured_at = replay
      Analysis.new(
        diff: Engine.compare(history.first_snapshot, final),
        timeline: ActivityRootSteps.call(plan, history.root_snapshots, closing_snapshot: snapshot,
                                                                       captured_at: captured_at),
        activity_timeline: present(steps),
        from_snapshot: history.first_snapshot,
        to_snapshot: final
      )
    end

    # Every boundary between the endpoints, filtered out or not: dropping one
    # would fold the change it carried into a neighbouring step and credit it
    # to whoever made that one. A version filter decides only which of the
    # steps are reported (see #reported?). Only the activity view gains the
    # closing removal. The endpoint diff and the root timeline keep their
    # `compare` and `timeline` semantics, under which the state at a destroy
    # version is the state before the deletion.
    #: () -> [RootVersionPlan, ActivityHistory, Array[ActivityStep], RecordSnapshot?, RecordSnapshot?, untyped]?
    def version_replay
      plan = select_plan
      history = history_until(plan)
      replayed(plan, history, closing_step(history, plan), history.last_snapshot)
    end

    # Activity replays every root version in the range, even those a version
    # filter leaves out, so that each change it keeps is read as the whole
    # history shows it. Only a window reads a context: an explicit range
    # always holds a version.
    #: () -> RootVersionPlan
    def select_plan = @range.select_plan(context_required: !@tree.empty?, whole: true)

    # Whether the event's step is reported: it is inside the range, and a
    # version filter keeps it. With associations the filter keeps whole
    # transactions (see ActivityScopeFilter). On the root alone it keeps the
    # root's versions, as `timeline` does, and so does a plan without one, but
    # for the version it holds only to reveal the last change in it.
    #: (ActivityEvent, RootVersionPlan) -> bool
    def reported?(event, plan)
      return false unless @range.include?(event.version)

      filter = @filter
      filter ? filter.kept?(event.version) : !event.root? || plan.mutation?(event.version)
    end

    # The explicit live endpoint and a batch's live closing endpoint use the
    # same selected plan, which replays every version through to the current
    # record, a version filter or not.
    #: () -> [RootVersionPlan, ActivityHistory, Array[ActivityStep], RecordSnapshot?, RecordSnapshot?, untyped]?
    def current_replay
      validate_current_range!
      plan = select_plan
      snapshot, captured_at = capture_current
      history = history_until(plan, snapshot, captured_at)
      live_replay(plan, history, @to, captured_at, snapshot)
    end

    # A range that closes after its last event ends at what closed it: the
    # live row, or nothing after a destroy, where no live row is read. One
    # that does not ends at the state its last reported step reached.
    #: (RootVersionPlan, ActivityHistory, untyped, untyped, RecordSnapshot?) -> [RootVersionPlan, ActivityHistory, Array[ActivityStep], RecordSnapshot?, RecordSnapshot?, untyped]?
    def live_replay(plan, history, live, captured_at, snapshot)
      closing = closing_step(history, plan, live, captured_at, snapshot)
      replayed(plan, history, closing, closing ? snapshot : history.last_snapshot, snapshot,
               captured_at)
    end

    #: (RootVersionPlan, ?RecordSnapshot?, ?untyped) -> ActivityHistory
    def history_until(plan, snapshot = nil, captured_at = nil)
      events, snapshots = range_events(plan, captured_at)
      replay(plan, events, snapshots, current: plan.closing_record, closing: snapshot)
    end

    # The range's events up to its last root version, or to the instant the
    # live record it closes on was read, with the history they are read from.
    #: (RootVersionPlan, untyped) -> [Array[ActivityEvent], untyped]
    def range_events(plan, captured_at)
      versions = plan.reconstruction_versions
      snapshots = prepare_history(versions, end_at: captured_at)
      [collect_events(versions, snapshots, range_end: captured_at || versions.last), snapshots]
    end

    #: () -> [RecordSnapshot?, untyped]
    def capture_current
      [@snapshotter.call(@to, @to), Time.now.utc]
    end

    #: () -> void
    def validate_current_range!
      unless Endpoint.version?(@range.from)
        raise InvalidTimelineRangeError, '`from` must be a root PaperTrail version'
      end

      Endpoint.validate_pair!(@range.from, @to)
      reject_live_habtm!
    end

    # A window with no selected event reports nothing, and so does one whose
    # replay left out every event it selected, each of a record outside the
    # tree throughout, such as a comment created outside a scope. Any other
    # has a boundary after its last event: the plan refuses a window that has
    # no later version, ends on no destroy, and does not close on the live row.
    #
    # A window closing on current state runs to the instant it is captured,
    # not to the last root version, or descendants that moved after that
    # version would be missing from a report that claims to reach now.
    #: () -> [RootVersionPlan, ActivityHistory, Array[ActivityStep], RecordSnapshot?, RecordSnapshot?, untyped]?
    def window_replay
      plan = select_plan
      live = plan.closing_record
      reject_live_habtm! if live
      window_activity(plan, live, (Time.now.utc if live)) unless plan.empty? && !live
    end

    # The live record is read only once something in the window is reported.
    #: (RootVersionPlan, untyped, untyped) -> [RootVersionPlan, ActivityHistory, Array[ActivityStep], RecordSnapshot?, RecordSnapshot?, untyped]?
    def window_activity(plan, live, captured_at)
      events, snapshots = range_events(plan, captured_at)
      return unless events.any? { |event| reported?(event, plan) }

      snapshot = (@snapshotter.call(live, live) if live)
      history = replay(plan, events, snapshots, current: live, closing: snapshot)
      live_replay(plan, history, live, captured_at, snapshot)
    end

    # The step that closes the range after its last event, which is reported
    # as that event's step would be. It runs from the last boundary the
    # history kept into one no version can supply: the live record the range
    # closes on, or the absence a final root destroy leaves.
    #
    # Everything recorded means on every requested path, not only the root's
    # own versions. When an association changed after a window, its last step
    # already ends at that change, at the state the window left, and that
    # change is the last kept event, outside the window; closing on current
    # state would add it to a window it was not in. A plan that does not close
    # on the current record holds a version after the window, which is such a
    # change, or ends at a destruction.
    #: (ActivityHistory, RootVersionPlan, ?untyped, ?untyped, ?RecordSnapshot?) -> ActivityStep?
    def closing_step(history, plan, live = nil, captured_at = nil, snapshot = nil)
      boundary = closing_boundary(history.last_event, plan, live, captured_at)
      return unless boundary

      last = history.last_boundary #: ActivityBoundary
      ActivityStep.between(
        from_boundary: last, to_boundary: boundary,
        from_snapshot: history.last_event_snapshot, to_snapshot: snapshot,
        retain: @view.retain?
      )
    end

    # Without a live record to close on, a range closes only on the root's
    # destruction, and its last event is then the root's own: the version
    # that ends an explicit range, or a window's version after it, or the
    # destroy nothing follows.
    #: (ActivityEvent?, RootVersionPlan, untyped, untyped) -> ActivityBoundary?
    def closing_boundary(event, plan, live, captured_at)
      return unless event && reported?(event, plan)

      if live
        ActivityBoundary.current(live, captured_at: captured_at, recorded: root_recorded)
      elsif event.version.event == 'destroy'
        ActivityBoundary.destroyed(event.version, recorded: root_recorded)
      end
    end

    #: () -> void
    def reject_live_habtm!
      AssociationTraversal.new(@tree).reject_live_habtm_activity!(@record.class)
    end

    #: () -> RecordedChangesReader?
    def root_recorded
      @view.recorded_reader(root: true)
    end

    # A window prepares from its start, explicit endpoints from their first
    # version.
    #: (Array[untyped], end_at: untyped) -> untyped
    def prepare_history(root_versions, end_at:)
      options = { start_at: @range.begin_time, end_at: end_at }.compact
      @snapshotter.prepare(@record, root_versions, **options)
    end

    # A window collects from its start, explicit endpoints from their first
    # version. Explicit endpoints also stop before the rest of the closing
    # version's transaction (see ActivityTransactionGroups.before_closing); a
    # window keeps every event it collected and reports only those inside it.
    #: (Array[untyped], untyped, range_end: untyped) -> Array[ActivityEvent]
    def collect_events(root_versions, snapshots, range_end:)
      events = ActivityVersionCollector.new(
        @record,
        root_versions: root_versions,
        tree: @tree,
        prepared: snapshots.activity_index,
        range_start: @range.begin_time || root_versions.first,
        range_end: range_end
      ).call
      events = ActivityTransactionGroups.before_closing(events, range_end) unless @range.time?
      prepare_filter(snapshots, events)
      events
    end

    # A version filter reads its answers for a batch's history once, for the
    # first root that history serves.
    #: (untyped, Array[ActivityEvent]) -> void
    def prepare_filter(snapshots, events)
      @filter&.prepare(snapshots.history, events.map(&:version))
    end

    # Events after the last root version read the root from the live record
    # when the range closes on it. Explicit endpoints report every step their
    # plan does, as their range includes every version.
    #: (RootVersionPlan, Array[ActivityEvent], untyped, current: untyped, closing: RecordSnapshot?) -> ActivityHistory
    def replay(plan, events, snapshots, current:, closing:)
      ActivityHistoryBuilder.new(
        plan.reconstruction_versions, events, snapshots,
        current: current,
        include_step: ->(event) { reported?(event, plan) },
        view: @view,
        closing: closing
      ).call
    end

    #: (Array[ActivityStep]) -> Array[ActivityStep]
    def present(steps)
      @view.present(steps).freeze
    end
  end
end
