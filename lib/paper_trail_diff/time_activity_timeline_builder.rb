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
      history, = history_and_versions
      history.steps
    end

    #: () -> Analysis
    def analyze
      history, root_versions = history_and_versions
      Analysis.new(
        diff: Engine.compare(history.first_snapshot, history.last_snapshot),
        timeline: root_steps(root_versions, history.root_snapshots),
        activity_timeline: history.steps
      )
    end

    private

    # @rbs @record: untyped
    # @rbs @range: TimelineRange
    # @rbs @tree: AssociationTree
    # @rbs @snapshotter: untyped

    #: () -> [ActivityHistory, Array[untyped]]
    def history_and_versions
      root_versions = @range.select(context_required: !@tree.empty?)
      return [ActivityHistory.empty, root_versions] if root_versions.empty?

      prepare_history(root_versions)
      events = collect_events(root_versions)
      return [ActivityHistory.empty, root_versions] unless time_events?(events)

      history = ActivityHistoryBuilder.new(
        root_versions,
        events,
        @snapshotter,
        include_step: ->(event) { @range.include?(event.version) }
      ).call
      [history, root_versions]
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

    #: (Array[ActivityEvent]) -> bool
    def time_events?(events)
      selected = events.select { |event| @range.include?(event.version) }
      return false if selected.empty?
      return true if later_event?(selected.last, events)

      message = 'time range requires a later activity boundary to reconstruct its final change'
      raise IncompleteTimeRangeError, message
    end

    #: (ActivityEvent, Array[ActivityEvent]) -> bool
    def later_event?(selected, events)
      events.any? do |event|
        Support.compare_versions(selected.version, event.version).negative?
      end
    end

    #: (Array[untyped], Hash[Array[untyped], RecordSnapshot?]) -> Array[Step]
    def root_steps(root_versions, root_snapshots)
      snapshots = root_versions.map do |version|
        root_snapshots.fetch(version_key(version))
      end
      root_versions.each_cons(2).with_index.map do |versions, index|
        Step.new(
          from_version: versions.fetch(0),
          to_version: versions.fetch(1),
          diff: Engine.compare(snapshots.fetch(index), snapshots.fetch(index + 1))
        )
      end.freeze
    end

    #: (untyped) -> Array[untyped]
    def version_key(version)
      [version.class.name, version.id]
    end
  end
end
