# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Builds activity views for mutations selected by a wall-clock range.
  class TimeActivityTimelineBuilder
    #: (untyped, range: TimelineRange, tree: AssociationTree, snapshotter: untyped, view: ActivityView) -> void
    def initialize(record, range:, tree:, snapshotter:, view:)
      @view = view
      @record = record
      @range = range
      @tree = tree
      @snapshotter = snapshotter
    end

    #: () -> Array[ActivityStep]
    def build
      history, _plan, closing, = history_and_versions
      activity_steps(history, closing)
    end

    #: () -> Analysis
    def analyze
      history, plan, closing, closing_snapshot, captured_at = history_and_versions
      final = final_snapshot(history, plan, closing, closing_snapshot)
      Analysis.new(
        diff: Engine.compare(history.first_snapshot, final),
        timeline: ActivityRootSteps.call(
          plan, history.root_snapshots,
          closing_snapshot: closing_snapshot, captured_at: captured_at
        ),
        activity_timeline: activity_steps(history, closing),
        from_snapshot: history.first_snapshot,
        to_snapshot: final
      )
    end

    private

    # @rbs @record: untyped
    # @rbs @range: TimelineRange

    # A window that closes on the current record ends there; one that ends
    # before a later event ends at the state that event found.
    #: (ActivityHistory, RootVersionPlan, ActivityStep?, RecordSnapshot?) -> RecordSnapshot?
    def final_snapshot(history, plan, closing, closing_snapshot)
      return if plan.closes_on_destroy
      return history.last_snapshot unless closing&.to_boundary&.kind == :current

      closing_snapshot
    end
    # @rbs @tree: AssociationTree
    # @rbs @snapshotter: untyped
    # @rbs @view: ActivityView

    #: () -> [ActivityHistory, RootVersionPlan, ActivityStep?, RecordSnapshot?, untyped]
    def history_and_versions
      plan = @range.select_plan(context_required: !@tree.empty?)
      reject_live_habtm! if plan.closing_record
      if plan.reconstruction_versions.empty? && !plan.closing_record
        return [ActivityHistory.empty, plan, nil, nil, nil]
      end

      # A window closing on current state runs to the instant it is captured,
      # not to the last root version, or descendants that moved after that
      # version would be missing from a report that claims to reach now.
      history_for(plan, plan.closing_record ? Time.now.utc : nil)
    end

    #: () -> void
    def reject_live_habtm!
      AssociationTraversal.new(@tree).reject_live_habtm_activity!(@record.class)
    end

    #: (RootVersionPlan, untyped) -> [ActivityHistory, RootVersionPlan, ActivityStep?, RecordSnapshot?, untyped]
    def history_for(plan, captured_at)
      root_versions = plan.reconstruction_versions
      snapshots, events = events_through(root_versions, captured_at)
      selected = selected_events(events, plan)
      unless time_events?(selected, events, plan)
        return [ActivityHistory.empty, plan, nil, nil, nil]
      end

      snapshot = current_snapshot(plan)
      history = build_history(root_versions, events, snapshots, current: plan.closing_record,
                                                                closing: snapshot)
      closing = closing_step(history, selected.last, plan, captured_at, snapshot, events)
      [history, plan, closing, snapshot, captured_at]
    end

    # One live read serves both the closing activity step and the endpoint the
    # analysis reports, which would otherwise reconstruct the graph twice.
    #: (RootVersionPlan) -> RecordSnapshot?
    def current_snapshot(plan)
      record = plan.closing_record
      return unless record

      @snapshotter.call(record, record)
    end

    #: (Array[untyped], untyped) -> [untyped, Array[ActivityEvent]]
    def events_through(root_versions, captured_at)
      snapshots = prepare_history(root_versions, end_at: captured_at)
      [snapshots, collect_events(root_versions, snapshots, range_end: captured_at)]
    end

    # Events after the last root version read the root from the live record
    # when the window closes on it, as an explicit `to: record` range does.
    #: (Array[untyped], Array[ActivityEvent], untyped, current: untyped, closing: RecordSnapshot?) -> ActivityHistory
    def build_history(root_versions, events, snapshots, current:, closing:)
      ActivityHistoryBuilder.new(
        root_versions, events, snapshots,
        current: current,
        include_step: ->(event) { @range.include?(event.version) },
        view: @view,
        closing: closing
      ).call
    end

    #: (ActivityHistory, ActivityStep?) -> Array[ActivityStep]
    def activity_steps(history, closing)
      steps = closing ? history.steps + [closing] : history.steps
      @view.present(steps).freeze
    end

    # Root versions inside the window that the plan does not report are context
    # rather than mutations: the version appended to reveal the last selected
    # change, and anything a filter excluded but the replay still walks. Neither
    # may be counted as a selected mutation. Descendant events are not filtered,
    # so window membership is the whole test for them.
    #: (Array[ActivityEvent], RootVersionPlan) -> Array[ActivityEvent]
    def selected_events(events, plan)
      events.select do |event|
        next false unless @range.include?(event.version)

        !event.root? || plan.mutation?(event.version)
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
    #: (ActivityHistory, ActivityEvent?, RootVersionPlan, untyped, RecordSnapshot?, Array[ActivityEvent]) -> ActivityStep?
    def closing_step(history, event, plan, captured_at, snapshot, events) # rubocop:disable Metrics/ParameterLists
      return unless event
      return destroyed_step(history, event) if terminal_destroy?(event)
      return unless plan.closing_record
      return if events.any? { |later| !@range.include?(later.version) }

      current_step(history, plan.closing_record, captured_at, snapshot)
    end

    #: (ActivityHistory, ActivityEvent) -> ActivityStep
    def destroyed_step(history, event)
      version = event.version
      recorded = @view.recorded_attributes(root: true)
      ActivityStep.between(
        from_boundary: ActivityBoundary.from_version(version, recorded: recorded),
        to_boundary: ActivityBoundary.destroyed(version, recorded: recorded),
        from_snapshot: history.root_snapshots[ActivityRootSteps.version_key(version)],
        to_snapshot: nil, retain: @view.retain?
      )
    end

    # The last boundary reached is where current state is compared from, which
    # is the final event rather than the final root version once descendants
    # have moved since it.
    #: (ActivityHistory, untyped, untyped, RecordSnapshot?) -> ActivityStep?
    def current_step(history, record, captured_at, snapshot)
      previous = history.last_boundary
      return unless previous

      recorded = @view.recorded_attributes(root: true)
      ActivityStep.between(
        from_boundary: previous,
        to_boundary: ActivityBoundary.current(record, captured_at: captured_at, recorded: recorded),
        from_snapshot: history.last_event_snapshot, to_snapshot: snapshot, retain: @view.retain?
      )
    end

    #: (ActivityEvent?) -> bool
    def terminal_destroy?(event)
      return false unless event

      event.root? && event.version.event.to_s == 'destroy'
    end

    #: (Array[untyped], ?end_at: untyped) -> untyped
    def prepare_history(root_versions, end_at: nil)
      start_at = @range.begin_time
      return @snapshotter.prepare(@record, root_versions, start_at: start_at) unless end_at

      @snapshotter.prepare(@record, root_versions, start_at: start_at, end_at: end_at)
    end

    #: (Array[untyped], untyped, ?range_end: untyped) -> Array[ActivityEvent]
    def collect_events(root_versions, snapshots, range_end: nil)
      ActivityVersionCollector.new(
        @record,
        root_versions: root_versions,
        tree: @tree,
        prepared: snapshots.activity_index,
        range_start: @range.begin_time,
        range_end: range_end || root_versions.last
      ).call
    end

    #: (Array[ActivityEvent], Array[ActivityEvent], RootVersionPlan) -> bool
    def time_events?(selected, events, plan)
      return false if selected.empty?
      return true if later_event?(selected.last, events)
      return true if terminal_destroy?(selected.last)
      return true if plan.closing_record

      message = 'time range requires a later activity boundary to reconstruct its ' \
                'final change: pass a saved record to end at its current state, ' \
                'or narrow the window to end before the last recorded boundary'
      raise IncompleteTimeRangeError, message
    end

    #: (ActivityEvent, Array[ActivityEvent]) -> bool
    def later_event?(selected, events)
      events.any? do |event|
        Support.compare_versions(selected.version, event.version).negative?
      end
    end
  end
end
