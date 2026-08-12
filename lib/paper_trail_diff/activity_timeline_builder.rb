# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Compares adjacent root and selected-descendant activity boundaries.
  class ActivityTimelineBuilder
    #: (untyped, range: TimelineRange, tree: AssociationTree, snapshotter: untyped, ?snapshots: bool) -> void
    def initialize(record, range:, tree:, snapshotter:, snapshots: false)
      @snapshots = snapshots
      @record = record
      @from = range.from
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

      unless Endpoint.version?(@to)
        raise InvalidTimelineRangeError, '`to` must be a root PaperTrail version'
      end

      plan = @range.select_plan
      root_versions = plan.reconstruction_versions
      prepare_history(root_versions)
      events = collect_events(root_versions)
      build_analysis(plan, events, event_history(root_versions, events))
    end

    private

    # @rbs @record: untyped
    # @rbs @from: untyped
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
    # credit them to whoever made that one.
    #: () -> Array[ActivityStep]
    def build_between_versions
      root_versions = @range.select_plan.reconstruction_versions
      prepare_history(root_versions)
      events = collect_events(root_versions)
      build_event_steps(root_versions, events)
    end

    #: () -> Array[ActivityStep]
    def build_to_current
      validate_current_range!
      current_snapshot, captured_at = capture_current
      root_versions = VersionRange.new(@record, from: @from, to: @from).select_through_latest
      # Descendants can move after the last root version, so the prepared range
      # ends at the captured instant rather than at that version.
      prepare_history(root_versions, end_at: captured_at)
      events = collect_events(root_versions, range_end: captured_at)
      build_event_steps(
        root_versions,
        events,
        current: @to,
        final_boundary: ActivityBoundary.current(@to, captured_at: captured_at),
        final_snapshot: current_snapshot
      )
    end

    #: () -> [RecordSnapshot?, untyped]
    def capture_current
      [@snapshotter.call(@to, @to), Time.now.utc]
    end

    #: () -> void
    def validate_current_range!
      unless Endpoint.version?(@from)
        raise InvalidTimelineRangeError, '`from` must be a root PaperTrail version'
      end

      Endpoint.validate_pair!(@from, @to)
      Endpoint.validate_pair!(@record, @to)
    end

    #: (Array[untyped], ?range_start: untyped, ?range_end: untyped) -> Array[ActivityEvent]
    def collect_events(
      root_versions,
      range_start: root_versions.first,
      range_end: root_versions.last
    )
      ActivityVersionCollector.new(
        @record,
        root_versions: root_versions,
        tree: @tree,
        traversal: AssociationTraversal.new(@tree),
        range_start: range_start,
        range_end: range_end
      ).call
    end

    #: (Array[untyped], ?end_at: untyped) -> void
    def prepare_history(root_versions, end_at: nil)
      return unless @snapshotter.respond_to?(:prepare)
      return @snapshotter.prepare(@record, root_versions) unless end_at

      @snapshotter.prepare(@record, root_versions, end_at: end_at)
    end

    #: (Array[untyped], Array[ActivityEvent], ?current: untyped, ?final_boundary: ActivityBoundary?, ?final_snapshot: RecordSnapshot?) -> Array[ActivityStep]
    def build_event_steps(
      root_versions,
      events,
      current: nil,
      final_boundary: nil,
      final_snapshot: nil
    )
      history = event_history(root_versions, events, current: current)
      activity_steps(
        history,
        events,
        final_boundary || destroyed_boundary(root_versions),
        final_snapshot
      )
    end

    # Appends the transition into an explicit closing boundary, which is either
    # a requested current record or the absence a final root destroy leaves.
    #: (ActivityHistory, Array[ActivityEvent], ActivityBoundary?, RecordSnapshot?) -> Array[ActivityStep]
    def activity_steps(history, events, final_boundary, final_snapshot)
      steps = history.steps.dup
      previous_event = events.last
      previous_boundary = ActivityBoundary.from_version(previous_event.version) if previous_event
      if final_boundary && previous_boundary
        steps << ActivityStep.between(
          from_boundary: previous_boundary, to_boundary: final_boundary,
          from_snapshot: history.last_snapshot, to_snapshot: final_snapshot,
          retain: @snapshots
        )
      end
      steps.freeze
    end

    # A destroyed root has no later version, but its own event states that
    # nothing follows it, so the removal can still close the timeline.
    #: (Array[untyped]) -> ActivityBoundary?
    def destroyed_boundary(root_versions)
      version = root_versions.last
      return unless version && version.event.to_s == 'destroy'

      ActivityBoundary.destroyed(version)
    end

    #: (Array[untyped], Array[ActivityEvent], ?current: untyped) -> ActivityHistory
    def event_history(root_versions, events, current: nil)
      ActivityHistoryBuilder.new(
        root_versions,
        events,
        @snapshotter,
        current: current,
        snapshots: @snapshots
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
      TimeActivityTimelineBuilder.new(
        @record,
        range: @range,
        tree: @tree,
        snapshotter: @snapshotter,
        snapshots: @snapshots
      )
    end
  end
end
