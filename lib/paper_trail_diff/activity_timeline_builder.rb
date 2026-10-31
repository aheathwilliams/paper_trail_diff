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
    end

    #: () -> Array[ActivityStep]
    def build
      return window_steps if @range.time?
      return no_steps if @range.unresolved?
      return build_to_current if Endpoint.record?(@to)

      Endpoint.validate!(@to)
      build_between_versions
    end

    # Builds the endpoint diff, the root timeline, and the activity from one
    # activity snapshot pass.
    #: () -> Analysis
    def analyze
      return analyze_window if @range.time?
      return Analysis.empty if @range.unresolved?
      return analyze_current if Endpoint.record?(@to)

      plan = @range.select_plan
      return Analysis.empty if plan.empty?

      build_analysis(plan, version_history(plan.reconstruction_versions))
    end

    private

    # @rbs @record: untyped
    # @rbs @to: untyped
    # @rbs @range: TimelineRange
    # @rbs @tree: AssociationTree
    # @rbs @snapshotter: untyped
    # @rbs @view: ActivityView

    #: () -> Array[ActivityStep]
    def no_steps
      steps = [] #: Array[ActivityStep]
      steps.freeze
    end

    # Every boundary in the span, filtered out or not. A filter narrows where the
    # span starts and ends, but the sequence inside it stays complete: dropping
    # boundaries would fold the changes they carried into a neighbouring step and
    # credit them to whoever made that one. A filter that keeps no version
    # leaves no span, as it does for a checkpoint timeline.
    #: () -> Array[ActivityStep]
    def build_between_versions
      plan = @range.select_plan
      return no_steps if plan.empty?

      root_versions = plan.reconstruction_versions
      activity_steps(version_history(root_versions), destroyed_boundary(root_versions), nil)
    end

    # Activity from the first to the last of the root versions.
    #: (Array[untyped]) -> ActivityHistory
    def version_history(root_versions)
      snapshots = prepare_history(root_versions)
      events = collect_events(root_versions, snapshots, range_end: root_versions.last)
      replay(root_versions, events, snapshots)
    end

    #: () -> Array[ActivityStep]
    def build_to_current
      _plan, history, snapshot, boundary = current_history
      activity_steps(history, boundary, snapshot)
    end

    #: () -> Analysis
    def analyze_current
      plan, history, snapshot, boundary = current_history
      analysis(plan, history, final: boundary ? snapshot : history.last_snapshot,
                              steps: activity_steps(history, boundary, snapshot),
                              closing_snapshot: snapshot, captured_at: boundary&.recorded_at)
    end

    # The explicit live endpoint and a batch's live closing endpoint use the
    # same selected plan. A version filter can close earlier, on its successor.
    #: () -> [RootVersionPlan, ActivityHistory, RecordSnapshot?, ActivityBoundary?]
    def current_history
      validate_current_range!
      plan = @range.select_plan
      return empty_history(plan) if plan.empty?

      snapshot, captured_at = capture_current if plan.closing_record
      history = history_until(plan, snapshot, captured_at)
      boundary = current_boundary(captured_at) if plan.closing_record
      [plan, history, snapshot, boundary]
    end

    # Events up to the instant the current record was read. A range that a
    # version filter closes earlier ends at that version, with no snapshot.
    #: (RootVersionPlan, RecordSnapshot?, untyped) -> ActivityHistory
    def history_until(plan, snapshot, captured_at)
      versions = plan.reconstruction_versions
      snapshots = prepare_history(versions, end_at: captured_at)
      events = collect_events(versions, snapshots, range_end: captured_at || versions.last)
      replay(versions, events, snapshots, current: plan.closing_record, closing: snapshot)
    end

    # Without a closing boundary nothing reads the closing pair, so its
    # mutations cannot change an answer.
    # mutant:disable
    #: (RootVersionPlan) -> [RootVersionPlan, ActivityHistory, RecordSnapshot?, ActivityBoundary?]
    def empty_history(plan)
      [plan, ActivityHistory.empty, nil, nil]
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
    #: (ActivityHistory, ActivityBoundary?, RecordSnapshot?) -> Array[ActivityStep]
    def activity_steps(history, final_boundary, final_snapshot)
      return present(history.steps) unless final_boundary

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
      steps = activity_steps(history, destroyed_boundary(plan.reconstruction_versions), nil)
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
      plan = @range.select_plan(context_required: !@tree.empty?)
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

    # A window with no selected event reports nothing. Any other has a
    # boundary after its last one: the plan refuses a window that has no later
    # version, ends on no destroy, and does not close on the live row.
    #: (RootVersionPlan, untyped) -> [ActivityHistory, RootVersionPlan, ActivityStep?, RecordSnapshot?, untyped]
    def window_replay(plan, captured_at)
      versions = plan.reconstruction_versions
      snapshots = prepare_history(versions, end_at: captured_at)
      events = collect_events(versions, snapshots, range_end: captured_at || versions.last)
      selected = selected_events(events, plan)
      last = selected.last
      return empty_window(plan) unless last

      snapshot = window_live_snapshot(plan)
      history = replay(versions, events, snapshots, current: plan.closing_record, closing: snapshot)
      closing = window_closing(history, last, plan, captured_at, snapshot, events)
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

    # Root versions inside the window that the plan does not report are context
    # rather than mutations: the version appended to reveal the last selected
    # change, and anything a filter excluded but the replay still walks. Neither
    # may be counted as a selected mutation. Descendant events are not filtered,
    # so window membership is the whole test for them.
    #: (Array[ActivityEvent], RootVersionPlan) -> Array[ActivityEvent]
    def selected_events(events, plan)
      events.select do |event|
        @range.include?(event.version) && (!event.root? || plan.mutation?(event.version))
      end
    end

    # A window either closes on the absence its final destruction leaves, or on
    # current state when it reaches past everything recorded. Both are boundaries
    # no version can supply.
    #
    # Everything recorded means on every requested path, not only the root's
    # own versions. When an association changed after the window, its last
    # step already ends at that change, at the state the window left; closing
    # on current state would add the later change to a window it was not in.
    #: (ActivityHistory, ActivityEvent, RootVersionPlan, untyped, RecordSnapshot?, Array[ActivityEvent]) -> ActivityStep?
    def window_closing(history, event, plan, captured_at, snapshot, events) # rubocop:disable Metrics/ParameterLists
      return window_destroyed_step(history, event) if terminal_destroy?(event)
      return unless plan.closing_record
      return if events.any? { |later| !@range.include?(later.version) }

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

    #: () -> Array[String]?
    def root_recorded
      @view.recorded_attributes(root: true)
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
      @range.time? ? events : ActivityTransactionGroups.before_closing(events, range_end)
    end

    # Events after the last root version read the root from the live record
    # when the range closes on it. Explicit endpoints report every step, as
    # their range includes every version.
    #: (Array[untyped], Array[ActivityEvent], untyped, ?current: untyped, ?closing: RecordSnapshot?) -> ActivityHistory
    def replay(root_versions, events, snapshots, current: nil, closing: nil)
      ActivityHistoryBuilder.new(
        root_versions, events, snapshots,
        current: current,
        include_step: ->(event) { @range.include?(event.version) },
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
