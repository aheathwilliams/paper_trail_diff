# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Compares adjacent root and selected-descendant activity boundaries.
  class ActivityTimelineBuilder
    #: (untyped, from: untyped, to: untyped, tree: AssociationTree, snapshotter: untyped) -> void
    def initialize(record, from:, to:, tree:, snapshotter:)
      @record = record
      @from = from
      @to = to
      @tree = tree
      @snapshotter = snapshotter
    end

    #: () -> Array[ActivityStep]
    def build
      return build_to_current if Endpoint.record?(@to)

      Endpoint.validate!(@to)
      build_between_versions
    end

    private

    # @rbs @record: untyped
    # @rbs @from: untyped
    # @rbs @to: untyped
    # @rbs @tree: AssociationTree
    # @rbs @snapshotter: untyped

    #: () -> Array[ActivityStep]
    def build_between_versions
      root_versions = VersionRange.new(@record, from: @from, to: @to).select
      events = collect_events(root_versions)
      snapshots = event_snapshots(root_versions, events)
      boundaries = events.map { |event| ActivityBoundary.from_version(event.version) }
      build_steps(boundaries, snapshots)
    end

    #: () -> Array[ActivityStep]
    def build_to_current
      validate_current_range!
      current_snapshot, captured_at = capture_current
      events, snapshots = history_to_current(captured_at)
      boundaries = boundaries_to_current(events, captured_at)
      build_steps(boundaries, snapshots + [current_snapshot])
    end

    #: () -> [RecordSnapshot?, untyped]
    def capture_current
      [@snapshotter.call(@to, @to), Time.now.utc]
    end

    #: (untyped) -> [Array[ActivityEvent], Array[RecordSnapshot?]]
    def history_to_current(captured_at)
      root_versions = VersionRange.new(@record, from: @from, to: @from).select_through_latest
      events = collect_events(root_versions, range_end: captured_at)
      snapshots = event_snapshots(root_versions, events, current: @to)
      [events, snapshots]
    end

    #: (Array[ActivityEvent], untyped) -> Array[ActivityBoundary]
    def boundaries_to_current(events, captured_at)
      boundaries = events.map { |event| ActivityBoundary.from_version(event.version) }
      boundaries << ActivityBoundary.current(@to, captured_at: captured_at)
    end

    #: () -> void
    def validate_current_range!
      unless Endpoint.version?(@from)
        raise InvalidTimelineRangeError, '`from` must be a root PaperTrail version'
      end

      Endpoint.validate_pair!(@from, @to)
      Endpoint.validate_pair!(@record, @to)
    end

    #: (Array[untyped], ?range_end: untyped) -> Array[ActivityEvent]
    def collect_events(root_versions, range_end: root_versions.last)
      ActivityVersionCollector.new(
        @record,
        root_versions: root_versions,
        tree: @tree,
        traversal: AssociationTraversal.new(@tree),
        range_end: range_end
      ).call
    end

    #: (Array[untyped], Array[ActivityEvent], ?current: untyped) -> Array[RecordSnapshot?]
    def event_snapshots(root_versions, events, current: nil)
      ActivitySnapshotSequence.new(
        root_versions,
        events,
        @snapshotter,
        current: current
      ).call
    end

    #: (Array[ActivityBoundary], Array[RecordSnapshot?]) -> Array[ActivityStep]
    def build_steps(boundaries, snapshots)
      boundaries.each_cons(2).with_index.map do |pair, index|
        ActivityStep.new(
          from_boundary: pair.first,
          to_boundary: pair.last,
          diff: Engine.compare(snapshots.fetch(index), snapshots.fetch(index + 1))
        )
      end.freeze
    end
  end
end
