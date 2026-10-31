# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Compares adjacent root and selected-descendant activity boundaries.
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
      return time_builder.build if @range.time?
      return no_steps if @range.unresolved?
      return build_to_current if Endpoint.record?(@to)

      Endpoint.validate!(@to)
      build_between_versions
    end

    # Builds all three version-bounded views from one activity snapshot pass.
    #: () -> Analysis
    def analyze
      return time_builder.analyze if @range.time?
      return Analysis.empty if @range.unresolved?
      return analyze_current if Endpoint.record?(@to)

      plan = @range.select_plan
      return Analysis.empty if plan.empty?

      root_versions = plan.reconstruction_versions
      prepare_history(root_versions)
      events = collect_events(root_versions)
      build_analysis(plan, event_history(root_versions, events))
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
      prepare_history(root_versions)
      events = collect_events(root_versions)
      history = event_history(root_versions, events)
      activity_steps(history, destroyed_boundary(root_versions), nil)
    end

    #: () -> Array[ActivityStep]
    def build_to_current
      _plan, history, snapshot, boundary = current_history
      activity_steps(history, boundary, snapshot)
    end

    #: () -> Analysis
    def analyze_current
      plan, history, snapshot, boundary = current_history
      final = boundary ? snapshot : history.last_snapshot
      Analysis.new(
        diff: Engine.compare(history.first_snapshot, final),
        timeline: ActivityRootSteps.call(
          plan, history.root_snapshots, closing_snapshot: snapshot,
                                        captured_at: boundary&.recorded_at
        ),
        activity_timeline: activity_steps(history, boundary, snapshot),
        from_snapshot: history.first_snapshot, to_snapshot: final
      )
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
      prepare_history(versions, end_at: captured_at)
      events = collect_events(versions, range_end: captured_at || versions.last)
      event_history(versions, events, current: plan.closing_record, closing: snapshot)
    end

    # Without a closing boundary nothing reads the closing pair, so its
    # mutations cannot change an answer.
    # mutant:disable
    #: (RootVersionPlan) -> [RootVersionPlan, ActivityHistory, RecordSnapshot?, ActivityBoundary?]
    def empty_history(plan)
      [plan, ActivityHistory.empty, nil, nil]
    end

    #: () -> Array[String]?
    def root_recorded
      @view.recorded_attributes(root: true)
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
      AssociationTraversal.new(@tree).reject_live_habtm_activity!(@record.class)
    end

    #: (Array[untyped], ?range_start: untyped, ?range_end: untyped) -> Array[ActivityEvent]
    def collect_events(
      root_versions,
      range_start: root_versions.first,
      range_end: root_versions.last
    )
      events = ActivityVersionCollector.new(
        @record,
        root_versions: root_versions,
        tree: @tree,
        prepared: @snapshotter.activity_index,
        range_start: range_start,
        range_end: range_end
      ).call
      ActivityTransactionGroups.before_closing(events, range_end)
    end

    #: (Array[untyped], ?end_at: untyped) -> void
    def prepare_history(root_versions, end_at: nil)
      return @snapshotter.prepare(@record, root_versions) unless end_at

      @snapshotter.prepare(@record, root_versions, end_at: end_at)
    end

    # Appends the transition into an explicit closing boundary, which is either
    # a requested current record or the absence a final root destroy leaves.
    # Either follows the root versions, which are themselves events, so the
    # last boundary the history kept opens it.
    #: (ActivityHistory, ActivityBoundary?, RecordSnapshot?) -> Array[ActivityStep]
    def activity_steps(history, final_boundary, final_snapshot)
      steps = history.steps.dup
      if final_boundary
        last_boundary = history.last_boundary #: ActivityBoundary
        steps << ActivityStep.between(
          from_boundary: last_boundary, to_boundary: final_boundary,
          from_snapshot: history.last_event_snapshot, to_snapshot: final_snapshot,
          retain: @view.retain?
        )
      end
      @view.present(steps).freeze
    end

    # A destroyed root has no later version, but its own event states that
    # nothing follows it, so the removal can still close the timeline.
    #: (Array[untyped]) -> ActivityBoundary?
    def destroyed_boundary(root_versions)
      version = root_versions.last
      return unless version.event == 'destroy'

      ActivityBoundary.destroyed(version, recorded: root_recorded)
    end

    #: (Array[untyped], Array[ActivityEvent], ?current: untyped, ?closing: RecordSnapshot?) -> ActivityHistory
    def event_history(root_versions, events, current: nil, closing: nil)
      ActivityHistoryBuilder.new(
        root_versions,
        events,
        @snapshotter,
        current: current,
        view: @view,
        closing: closing
      ).call
    end

    # Only the activity view gains the closing removal. The endpoint diff and
    # the root timeline keep their `compare` and `timeline` semantics, under
    # which the state at a destroy version is the state before the deletion.
    #: (RootVersionPlan, ActivityHistory) -> Analysis
    def build_analysis(plan, history)
      Analysis.new(
        diff: Engine.compare(history.first_snapshot, history.last_snapshot),
        timeline: ActivityRootSteps.call(plan, history.root_snapshots),
        activity_timeline: activity_steps(
          history, destroyed_boundary(plan.reconstruction_versions), nil
        ),
        from_snapshot: history.first_snapshot,
        to_snapshot: history.last_snapshot
      )
    end

    #: () -> TimeActivityTimelineBuilder
    def time_builder
      TimeActivityTimelineBuilder.new(@record, range: @range, tree: @tree,
                                               snapshotter: @snapshotter, view: @view)
    end
  end
end
