# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Builds activity views for mutations selected by a wall-clock range.
  class TimeActivityTimelineBuilder
    #: (untyped, range: TimelineRange, tree: AssociationTree, snapshotter: untyped) -> void
    def initialize(record, range:, tree:, snapshotter:)
      @record = record
      @range = range
      @tree = tree
      @snapshotter = snapshotter
    end

    #: () -> Array[ActivityStep]
    def build
      history, _plan, closing = history_and_versions
      activity_steps(history, closing)
    end

    #: () -> Analysis
    def analyze
      history, plan, closing = history_and_versions
      Analysis.new(
        diff: Engine.compare(history.first_snapshot, history.last_snapshot),
        timeline: ActivityRootSteps.call(plan, history.root_snapshots),
        activity_timeline: activity_steps(history, closing),
        from_snapshot: history.first_snapshot,
        to_snapshot: history.last_snapshot
      )
    end

    private

    # @rbs @record: untyped
    # @rbs @range: TimelineRange
    # @rbs @tree: AssociationTree
    # @rbs @snapshotter: untyped

    #: () -> [ActivityHistory, RootVersionPlan, ActivityStep?]
    def history_and_versions
      plan = @range.select_plan(context_required: !@tree.empty?)
      root_versions = plan.reconstruction_versions
      return [ActivityHistory.empty, plan, nil] if root_versions.empty?

      prepare_history(root_versions)
      events = collect_events(root_versions)
      selected = selected_events(events, plan)
      return [ActivityHistory.empty, plan, nil] unless time_events?(selected, events)

      history = build_history(root_versions, events)
      [history, plan, closing_step(history, selected.last)]
    end

    #: (Array[untyped], Array[ActivityEvent]) -> ActivityHistory
    def build_history(root_versions, events)
      ActivityHistoryBuilder.new(
        root_versions,
        events,
        @snapshotter,
        include_step: ->(event) { @range.include?(event.version) }
      ).call
    end

    #: (ActivityHistory, ActivityStep?) -> Array[ActivityStep]
    def activity_steps(history, closing)
      return history.steps unless closing

      (history.steps + [closing]).freeze
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

    # The window's last selected mutation is the root's own destruction, so the
    # timeline closes on the absence it leaves rather than on a later boundary.
    #: (ActivityHistory, ActivityEvent?) -> ActivityStep?
    def closing_step(history, event)
      return unless event && terminal_destroy?(event)

      version = event.version
      ActivityStep.new(
        from_boundary: ActivityBoundary.from_version(version),
        to_boundary: ActivityBoundary.destroyed(version),
        diff: Engine.compare(history.root_snapshots[ActivityRootSteps.version_key(version)], nil)
      )
    end

    #: (ActivityEvent?) -> bool
    def terminal_destroy?(event)
      return false unless event

      event.root? && event.version.event.to_s == 'destroy'
    end

    #: (Array[untyped]) -> void
    def prepare_history(root_versions)
      return unless @snapshotter.respond_to?(:prepare)

      @snapshotter.prepare(@record, root_versions, start_at: @range.begin_time)
    end

    #: (Array[untyped]) -> Array[ActivityEvent]
    def collect_events(root_versions)
      ActivityVersionCollector.new(
        @record,
        root_versions: root_versions,
        tree: @tree,
        traversal: AssociationTraversal.new(@tree),
        range_start: @range.begin_time,
        range_end: root_versions.last
      ).call
    end

    #: (Array[ActivityEvent], Array[ActivityEvent]) -> bool
    def time_events?(selected, events)
      return false if selected.empty?
      return true if later_event?(selected.last, events)
      return true if terminal_destroy?(selected.last)

      message = 'time range requires a later activity boundary to reconstruct its final change'
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
