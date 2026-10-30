# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Compares adjacent root and selected-descendant activity boundaries.
  class ActivityTimelineBuilder
    include ActivityGrouping

    #: (untyped, range: TimelineRange, tree: AssociationTree, snapshotter: untyped, snapshots: bool, group: Symbol?) -> void
    def initialize(record, range:, tree:, snapshotter:, snapshots:, group:) # rubocop:disable Metrics/ParameterLists
      ActivityGrouping.validate!(group)
      @snapshots = snapshots
      @group = group
      # Merging a group compares its outer states, so the snapshots must survive
      # the build even when the caller did not ask to keep them.
      @retain = snapshots || grouping?
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
      build_analysis(plan, events, event_history(root_versions, events))
    end

    private

    # @rbs @record: untyped
    # @rbs @to: untyped
    # @rbs @range: TimelineRange
    # @rbs @tree: AssociationTree
    # @rbs @snapshotter: untyped
    # @rbs @snapshots: bool

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
      activity_steps(history, events, destroyed_boundary(root_versions), nil)
    end

    #: () -> Array[ActivityStep]
    def build_to_current
      _plan, events, history, snapshot, boundary = current_history
      activity_steps(history, events, boundary, snapshot)
    end

    #: () -> Analysis
    def analyze_current
      plan, events, history, snapshot, boundary = current_history
      final = boundary ? snapshot : history.last_snapshot
      Analysis.new(
        diff: Engine.compare(history.first_snapshot, final),
        timeline: ActivityRootSteps.call(
          plan, history.root_snapshots, closing_snapshot: snapshot,
                                        captured_at: boundary&.recorded_at
        ),
        activity_timeline: activity_steps(history, events, boundary, snapshot),
        from_snapshot: history.first_snapshot, to_snapshot: final
      )
    end

    # The explicit live endpoint and a batch's live closing endpoint use the
    # same selected plan. A version filter can close earlier, on its successor.
    #: () -> [RootVersionPlan, Array[ActivityEvent], ActivityHistory, RecordSnapshot?, ActivityBoundary?]
    def current_history
      validate_current_range!
      plan = @range.select_plan
      return empty_history(plan) if plan.empty?

      snapshot, captured_at = capture_current if plan.closing_record
      versions = plan.reconstruction_versions
      prepare_history(versions, end_at: captured_at)
      events = collect_events(versions, range_end: captured_at || versions.last)
      history = event_history(versions, events, current: plan.closing_record)
      boundary = ActivityBoundary.current(@to, captured_at: captured_at) if plan.closing_record
      [plan, events, history, snapshot, boundary]
    end

    # Without a closing boundary nothing reads the events or the closing pair,
    # so their mutations cannot change an answer.
    # mutant:disable
    #: (RootVersionPlan) -> [RootVersionPlan, Array[ActivityEvent], ActivityHistory, RecordSnapshot?, ActivityBoundary?]
    def empty_history(plan)
      [plan, [], ActivityHistory.empty, nil, nil]
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
        prepared: (@snapshotter.activity_index if @snapshotter.respond_to?(:activity_index)),
        range_start: range_start,
        range_end: range_end
      ).call
      ActivityTransactionGroups.before_closing(events, range_end)
    end

    #: (Array[untyped], ?end_at: untyped) -> void
    def prepare_history(root_versions, end_at: nil)
      return unless @snapshotter.respond_to?(:prepare)
      return @snapshotter.prepare(@record, root_versions) unless end_at

      @snapshotter.prepare(@record, root_versions, end_at: end_at)
    end

    # Appends the transition into an explicit closing boundary, which is either
    # a requested current record or the absence a final root destroy leaves.
    # Either follows the root versions, which are themselves events.
    #: (ActivityHistory, Array[ActivityEvent], ActivityBoundary?, RecordSnapshot?) -> Array[ActivityStep]
    def activity_steps(history, events, final_boundary, final_snapshot)
      steps = history.steps.dup
      if final_boundary
        last_event = events.last #: ActivityEvent
        steps << ActivityStep.between(
          from_boundary: ActivityBoundary.from_version(last_event.version),
          to_boundary: final_boundary,
          from_snapshot: history.last_snapshot, to_snapshot: final_snapshot,
          retain: @retain
        )
      end
      group_steps(steps).freeze
    end

    # A destroyed root has no later version, but its own event states that
    # nothing follows it, so the removal can still close the timeline.
    #: (Array[untyped]) -> ActivityBoundary?
    def destroyed_boundary(root_versions)
      version = root_versions.last
      return unless version.event == 'destroy'

      ActivityBoundary.destroyed(version)
    end

    #: (Array[untyped], Array[ActivityEvent], ?current: untyped) -> ActivityHistory
    def event_history(root_versions, events, current: nil)
      ActivityHistoryBuilder.new(
        root_versions,
        events,
        @snapshotter,
        current: current,
        snapshots: @retain
      ).call
    end

    # Only the activity view gains the closing removal. The endpoint diff and
    # the root timeline keep their `compare` and `timeline` semantics, under
    # which the state at a destroy version is the state before the deletion.
    #: (RootVersionPlan, Array[ActivityEvent], ActivityHistory) -> Analysis
    def build_analysis(plan, events, history)
      Analysis.new(
        diff: Engine.compare(history.first_snapshot, history.last_snapshot),
        timeline: ActivityRootSteps.call(plan, history.root_snapshots),
        activity_timeline: activity_steps(
          history, events, destroyed_boundary(plan.reconstruction_versions), nil
        ),
        from_snapshot: history.first_snapshot,
        to_snapshot: history.last_snapshot
      )
    end

    #: () -> TimeActivityTimelineBuilder
    def time_builder
      TimeActivityTimelineBuilder.new(@record, range: @range, tree: @tree,
                                               snapshotter: @snapshotter, snapshots: @snapshots,
                                               group: @group)
    end
  end
end
