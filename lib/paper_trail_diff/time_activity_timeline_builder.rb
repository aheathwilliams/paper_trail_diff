# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Builds activity views for mutations selected by a wall-clock range.
  class TimeActivityTimelineBuilder
    include ActivityGrouping

    #: (untyped, range: TimelineRange, tree: AssociationTree, snapshotter: untyped, ?snapshots: bool, ?group: Symbol?) -> void
    def initialize(record, range:, tree:, snapshotter:, snapshots: false, group: nil) # rubocop:disable Metrics/ParameterLists
      @snapshots = snapshots
      @group = group
      # Merging a group compares its outer states, so the snapshots must survive
      # the build even when the caller did not ask to keep them.
      @retain = snapshots || grouping?
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
      final = closing_snapshot || history.last_snapshot
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
    # @rbs @tree: AssociationTree
    # @rbs @snapshotter: untyped
    # @rbs @snapshots: bool

    #: () -> [ActivityHistory, RootVersionPlan, ActivityStep?, RecordSnapshot?, untyped]
    def history_and_versions
      plan = @range.select_plan(context_required: !@tree.empty?)
      return [ActivityHistory.empty, plan, nil, nil, nil] if plan.reconstruction_versions.empty?

      # A window closing on current state runs to the instant it is captured,
      # not to the last root version, or descendants that moved after that
      # version would be missing from a report that claims to reach now.
      history_for(plan, plan.closing_record ? Time.now.utc : nil)
    end

    #: (RootVersionPlan, untyped) -> [ActivityHistory, RootVersionPlan, ActivityStep?, RecordSnapshot?, untyped]
    def history_for(plan, captured_at)
      root_versions = plan.reconstruction_versions
      events = events_through(root_versions, captured_at)
      selected = selected_events(events, plan)
      unless time_events?(selected, events, plan)
        return [ActivityHistory.empty, plan, nil, nil, nil]
      end

      history = build_history(root_versions, events)
      snapshot = current_snapshot(plan)
      closing = closing_step(history, selected.last, plan, captured_at, snapshot)
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

    #: (Array[untyped], untyped) -> Array[ActivityEvent]
    def events_through(root_versions, captured_at)
      prepare_history(root_versions, end_at: captured_at)
      collect_events(root_versions, range_end: captured_at)
    end

    #: (Array[untyped], Array[ActivityEvent]) -> ActivityHistory
    def build_history(root_versions, events)
      ActivityHistoryBuilder.new(
        root_versions,
        events,
        @snapshotter,
        include_step: ->(event) { @range.include?(event.version) },
        snapshots: @retain
      ).call
    end

    #: (ActivityHistory, ActivityStep?) -> Array[ActivityStep]
    def activity_steps(history, closing)
      steps = closing ? history.steps + [closing] : history.steps
      group_steps(steps).freeze
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
    #: (ActivityHistory, ActivityEvent?, RootVersionPlan, untyped, RecordSnapshot?) -> ActivityStep?
    def closing_step(history, event, plan, captured_at, snapshot)
      return unless event
      return destroyed_step(history, event) if terminal_destroy?(event)
      return unless plan.closing_record

      current_step(history, plan.closing_record, captured_at, snapshot)
    end

    #: (ActivityHistory, ActivityEvent) -> ActivityStep
    def destroyed_step(history, event)
      version = event.version
      ActivityStep.between(
        from_boundary: ActivityBoundary.from_version(version),
        to_boundary: ActivityBoundary.destroyed(version),
        from_snapshot: history.root_snapshots[ActivityRootSteps.version_key(version)],
        to_snapshot: nil, retain: @retain
      )
    end

    # The last boundary reached is where current state is compared from, which
    # is the final event rather than the final root version once descendants
    # have moved since it.
    #: (ActivityHistory, untyped, untyped, RecordSnapshot?) -> ActivityStep?
    def current_step(history, record, captured_at, snapshot)
      previous = history.steps.last&.to_boundary
      return unless previous

      ActivityStep.between(
        from_boundary: previous,
        to_boundary: ActivityBoundary.current(record, captured_at: captured_at),
        from_snapshot: history.last_snapshot, to_snapshot: snapshot, retain: @retain
      )
    end

    #: (ActivityEvent?) -> bool
    def terminal_destroy?(event)
      return false unless event

      event.root? && event.version.event.to_s == 'destroy'
    end

    #: (Array[untyped], ?end_at: untyped) -> void
    def prepare_history(root_versions, end_at: nil)
      return unless @snapshotter.respond_to?(:prepare)

      start_at = @range.begin_time
      return @snapshotter.prepare(@record, root_versions, start_at: start_at) unless end_at

      @snapshotter.prepare(@record, root_versions, start_at: start_at, end_at: end_at)
    end

    #: (Array[untyped], ?range_end: untyped) -> Array[ActivityEvent]
    def collect_events(root_versions, range_end: nil)
      ActivityVersionCollector.new(
        @record,
        root_versions: root_versions,
        tree: @tree,
        traversal: AssociationTraversal.new(@tree),
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
                'final change: pass close_on: :current to end at current state, ' \
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
