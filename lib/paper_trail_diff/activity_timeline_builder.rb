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
      return window_steps if @range.time?
      return no_steps if @range.unresolved?
      return build_to_current if Endpoint.record?(@to)

      Endpoint.validate!(@to)
      build_between_versions
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
      return analyze_window if @range.time?
      return Analysis.empty if @range.unresolved?
      return analyze_current if Endpoint.record?(@to)

      plan = select_plan
      build_analysis(plan, version_history(plan))
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

    # Every boundary between the endpoints, filtered out or not: dropping one
    # would fold the change it carried into a neighbouring step and credit it
    # to whoever made that one. A version filter decides only which of the
    # steps are reported (see #reported?).
    #: () -> Array[ActivityStep]
    def build_between_versions
      plan = select_plan
      root_versions = plan.reconstruction_versions
      activity_steps(version_history(plan), plan, destroyed_boundary(root_versions), nil)
    end

    # Activity from the first to the last of the root versions.
    #: (RootVersionPlan) -> ActivityHistory
    def version_history(plan)
      root_versions = plan.reconstruction_versions
      snapshots = prepare_history(root_versions)
      events = collect_events(root_versions, snapshots, range_end: root_versions.last)
      replay(plan, events, snapshots)
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

    # A closing step is the last event's, so it is reported as that event's
    # step would be.
    #: (ActivityHistory, RootVersionPlan) -> bool
    def closes?(history, plan)
      event = history.last_event
      !event.nil? && reported?(event, plan)
    end

    #: () -> Array[ActivityStep]
    def build_to_current
      plan, history, snapshot, boundary = current_history
      activity_steps(history, plan, boundary, snapshot)
    end

    # The range ends at the current record when its last event's step is
    # reported, and at that step's end otherwise.
    #: () -> Analysis
    def analyze_current
      plan, history, snapshot, boundary = current_history
      analysis(plan, history, final: closes?(history, plan) ? snapshot : history.last_snapshot,
                              steps: activity_steps(history, plan, boundary, snapshot),
                              closing_snapshot: snapshot, captured_at: boundary.recorded_at)
    end

    # The explicit live endpoint and a batch's live closing endpoint use the
    # same selected plan, which replays every version through to the current
    # record, a version filter or not.
    #: () -> [RootVersionPlan, ActivityHistory, RecordSnapshot?, ActivityBoundary]
    def current_history
      validate_current_range!
      plan = select_plan
      snapshot, captured_at = capture_current
      history = history_until(plan, snapshot, captured_at)
      [plan, history, snapshot, current_boundary(captured_at)]
    end

    # Events up to the instant the current record was read.
    #: (RootVersionPlan, RecordSnapshot?, untyped) -> ActivityHistory
    def history_until(plan, snapshot, captured_at)
      versions = plan.reconstruction_versions
      snapshots = prepare_history(versions, end_at: captured_at)
      events = collect_events(versions, snapshots, range_end: captured_at)
      replay(plan, events, snapshots, current: plan.closing_record, closing: snapshot)
    end

    #: (untyped) -> ActivityBoundary
    def current_boundary(captured_at)
      ActivityBoundary.current(@to, captured_at: captured_at, recorded: root_recorded)
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

    # Appends the transition into an explicit closing boundary, which is either
    # a requested current record or the absence a final root destroy leaves.
    # Either follows the root versions, which are themselves events, so the
    # last boundary the history kept opens it.
    #: (ActivityHistory, RootVersionPlan, ActivityBoundary?, RecordSnapshot?) -> Array[ActivityStep]
    def activity_steps(history, plan, final_boundary, final_snapshot)
      return present(history.steps) unless final_boundary && closes?(history, plan)

      last_boundary = history.last_boundary #: ActivityBoundary
      present(history.steps + [step_from_last(history, last_boundary, final_boundary,
                                              final_snapshot)])
    end

    # A destroyed root has no later version, but its own event states that
    # nothing follows it, so the removal can still close the timeline.
    #: (Array[untyped]) -> ActivityBoundary?
    def destroyed_boundary(root_versions)
      version = root_versions.last
      return unless version.event == 'destroy'

      ActivityBoundary.destroyed(version, recorded: root_recorded)
    end

    # Only the activity view gains the closing removal. The endpoint diff and
    # the root timeline keep their `compare` and `timeline` semantics, under
    # which the state at a destroy version is the state before the deletion.
    #: (RootVersionPlan, ActivityHistory) -> Analysis
    def build_analysis(plan, history)
      steps = activity_steps(history, plan, destroyed_boundary(plan.reconstruction_versions), nil)
      analysis(plan, history, final: history.last_snapshot, steps: steps)
    end

    #: () -> Array[ActivityStep]
    def window_steps
      history, _plan, closing, = window_history
      present(closing ? history.steps + [closing] : history.steps)
    end

    #: () -> Analysis
    def analyze_window
      history, plan, closing, closing_snapshot, captured_at = window_history
      analysis(plan, history,
               final: window_final_snapshot(history, closing, closing_snapshot),
               steps: present(closing ? history.steps + [closing] : history.steps),
               closing_snapshot: closing_snapshot, captured_at: captured_at)
    end

    # A window with a closing step ends at what closed it: the live row, or
    # nothing after a destroy, where no live row is read. One that ends before
    # a later event ends at the state that event found.
    #: (ActivityHistory, ActivityStep?, RecordSnapshot?) -> RecordSnapshot?
    def window_final_snapshot(history, closing, closing_snapshot)
      closing ? closing_snapshot : history.last_snapshot
    end

    #: () -> [ActivityHistory, RootVersionPlan, ActivityStep?, RecordSnapshot?, untyped]
    def window_history
      plan = select_plan
      reject_live_habtm! if plan.closing_record
      return empty_window(plan) if plan.empty? && !plan.closing_record

      # A window closing on current state runs to the instant it is captured,
      # not to the last root version, or descendants that moved after that
      # version would be missing from a report that claims to reach now.
      window_replay(plan, (Time.now.utc if plan.closing_record))
    end

    # Nothing reads a window's closing step, live snapshot, or capture time
    # when it reported nothing, so mutations of those cannot change an answer.
    # mutant:disable
    #: (RootVersionPlan) -> [ActivityHistory, RootVersionPlan, ActivityStep?, RecordSnapshot?, untyped]
    def empty_window(plan)
      [ActivityHistory.empty, plan, nil, nil, nil]
    end

    # A window with no selected event reports nothing, and so does one whose
    # replay left out every event it selected, each of a record outside the
    # tree throughout, such as a comment created outside a scope: its
    # analysis is empty. Any other has a boundary after its last event: the
    # plan refuses a window that has no later version, ends on no destroy, and
    # does not close on the live row.
    #: (RootVersionPlan, untyped) -> [ActivityHistory, RootVersionPlan, ActivityStep?, RecordSnapshot?, untyped]
    def window_replay(plan, captured_at)
      versions = plan.reconstruction_versions
      snapshots = prepare_history(versions, end_at: captured_at)
      events = collect_events(versions, snapshots, range_end: captured_at || versions.last)
      last = selected_events(events, plan).last
      return empty_window(plan) unless last

      snapshot = window_live_snapshot(plan)
      history = replay(plan, events, snapshots, current: plan.closing_record, closing: snapshot)
      closing = window_closing(history, last, plan, captured_at, snapshot)
      window_result(plan, history, closing, snapshot, captured_at)
    end

    #: (RootVersionPlan, ActivityHistory, ActivityStep?, RecordSnapshot?, untyped) -> [ActivityHistory, RootVersionPlan, ActivityStep?, RecordSnapshot?, untyped]
    def window_result(plan, history, closing, snapshot, captured_at)
      return empty_window(plan) if history.steps.empty? && !closing

      [history, plan, closing, snapshot, captured_at]
    end

    # One live read serves both the closing activity step and the endpoint the
    # analysis reports, which would otherwise reconstruct the graph twice.
    #: (RootVersionPlan) -> RecordSnapshot?
    def window_live_snapshot(plan)
      record = plan.closing_record
      return unless record

      @snapshotter.call(record, record)
    end

    # The events whose steps are reported: not the version appended to reveal
    # the last selected change, nor anything a filter leaves out that the
    # replay still walks (see #reported?).
    #: (Array[ActivityEvent], RootVersionPlan) -> Array[ActivityEvent]
    def selected_events(events, plan)
      events.select { |event| reported?(event, plan) }
    end

    # A window either closes on the absence its final destruction leaves, or on
    # current state when it reaches past everything recorded. Both are boundaries
    # no version can supply. One whose replay kept no event, or whose last kept
    # event's step it does not report, has nothing to close.
    #
    # Everything recorded means on every requested path, not only the root's
    # own versions. When an association changed after the window, its last
    # step already ends at that change, at the state the window left, and that
    # change is the last kept event, outside the window; closing on current
    # state would add it to a window it was not in. A plan that does not close
    # on the current record holds a version after the window, which is such a
    # change, or ends at a destruction.
    #: (ActivityHistory, ActivityEvent, RootVersionPlan, untyped, RecordSnapshot?) -> ActivityStep?
    def window_closing(history, event, plan, captured_at, snapshot)
      return window_destroyed_step(history, event) if terminal_destroy?(event)
      return unless closes?(history, plan)

      window_current_step(history, plan.closing_record, captured_at, snapshot)
    end

    #: (ActivityHistory, ActivityEvent) -> ActivityStep
    def window_destroyed_step(history, event)
      version = event.version
      ActivityStep.between(
        from_boundary: ActivityBoundary.from_version(version, recorded: root_recorded),
        to_boundary: ActivityBoundary.destroyed(version, recorded: root_recorded),
        from_snapshot: history.root_snapshots.fetch(ActivityRootSteps.version_key(version)),
        to_snapshot: nil, retain: @view.retain?
      )
    end

    # The last boundary reached is where current state is compared from, which
    # is the final event rather than the final root version once descendants
    # have moved since it. A selected event is a boundary the history kept.
    #: (ActivityHistory, untyped, untyped, RecordSnapshot?) -> ActivityStep
    def window_current_step(history, record, captured_at, snapshot)
      previous = history.last_boundary #: ActivityBoundary
      current = ActivityBoundary.current(record, captured_at: captured_at, recorded: root_recorded)
      step_from_last(history, previous, current, snapshot)
    end

    #: (ActivityEvent) -> bool
    def terminal_destroy?(event)
      event.root? && event.version.event == 'destroy'
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
    #: (Array[untyped], ?end_at: untyped) -> untyped
    def prepare_history(root_versions, end_at: nil)
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
    #: (RootVersionPlan, Array[ActivityEvent], untyped, ?current: untyped, ?closing: RecordSnapshot?) -> ActivityHistory
    def replay(plan, events, snapshots, current: nil, closing: nil)
      ActivityHistoryBuilder.new(
        plan.reconstruction_versions, events, snapshots,
        current: current,
        include_step: ->(event) { reported?(event, plan) },
        view: @view,
        closing: closing
      ).call
    end

    # The step from the last boundary the history reached to one that closes
    # the range.
    #: (ActivityHistory, ActivityBoundary, ActivityBoundary, RecordSnapshot?) -> ActivityStep
    def step_from_last(history, last_boundary, closing_boundary, closing_snapshot)
      ActivityStep.between(
        from_boundary: last_boundary, to_boundary: closing_boundary,
        from_snapshot: history.last_event_snapshot, to_snapshot: closing_snapshot,
        retain: @view.retain?
      )
    end

    #: (Array[ActivityStep]) -> Array[ActivityStep]
    def present(steps)
      @view.present(steps).freeze
    end

    #: (RootVersionPlan, ActivityHistory, final: RecordSnapshot?, steps: Array[ActivityStep], ?closing_snapshot: RecordSnapshot?, ?captured_at: untyped) -> Analysis
    def analysis(plan, history, final:, steps:, **closing)
      Analysis.new(
        diff: Engine.compare(history.first_snapshot, final),
        timeline: ActivityRootSteps.call(plan, history.root_snapshots, **closing),
        activity_timeline: steps,
        from_snapshot: history.first_snapshot,
        to_snapshot: final
      )
    end
  end
end
