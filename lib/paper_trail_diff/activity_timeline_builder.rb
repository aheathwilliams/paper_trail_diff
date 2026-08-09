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

    # Builds all three version-bounded views from one activity snapshot pass.
    #: () -> Analysis
    def analyze
      unless Endpoint.version?(@to)
        raise InvalidTimelineRangeError, '`to` must be a root PaperTrail version'
      end

      root_versions = VersionRange.new(@record, from: @from, to: @to).select
      prepare_history(root_versions)
      events = collect_events(root_versions)
      activity_steps, root_snapshots, = event_history(root_versions, events)
      build_analysis(root_versions, root_snapshots, activity_steps)
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
      prepare_history(root_versions)
      events = collect_events(root_versions)
      build_event_steps(root_versions, events)
    end

    #: () -> Array[ActivityStep]
    def build_to_current
      validate_current_range!
      current_snapshot, captured_at = capture_current
      root_versions = VersionRange.new(@record, from: @from, to: @from).select_through_latest
      prepare_history(root_versions)
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

    #: (Array[untyped]) -> void
    def prepare_history(root_versions)
      @snapshotter.prepare(@record, root_versions) if @snapshotter.respond_to?(:prepare)
    end

    #: (Array[untyped], Array[ActivityEvent], ?current: untyped, ?final_boundary: ActivityBoundary?, ?final_snapshot: RecordSnapshot?) -> Array[ActivityStep]
    def build_event_steps(
      root_versions,
      events,
      current: nil,
      final_boundary: nil,
      final_snapshot: nil
    )
      steps, _root_snapshots, previous_snapshot = event_history(
        root_versions,
        events,
        current: current
      )
      previous_event = events.last
      previous_boundary = ActivityBoundary.from_version(previous_event.version) if previous_event
      if final_boundary && previous_boundary
        steps << ActivityStep.new(
          from_boundary: previous_boundary,
          to_boundary: final_boundary,
          diff: Engine.compare(previous_snapshot, final_snapshot)
        )
      end
      steps.freeze
    end

    #: (Array[untyped], Array[ActivityEvent], ?current: untyped) -> [Array[ActivityStep], Hash[Array[untyped], RecordSnapshot?], RecordSnapshot?]
    def event_history(root_versions, events, current: nil) # rubocop:disable Metrics/MethodLength
      sequence = ActivitySnapshotSequence.new(root_versions, events, @snapshotter, current: current)
      steps = [] #: Array[ActivityStep]
      root_snapshots = {} #: Hash[Array[untyped], RecordSnapshot?]
      previous_boundary = nil #: ActivityBoundary?
      previous_snapshot = nil #: RecordSnapshot?
      sequence.each do |event, snapshot|
        boundary = ActivityBoundary.from_version(event.version)
        root_snapshots[version_key(event.version)] = snapshot if event.root?
        if previous_boundary
          steps << ActivityStep.new(
            from_boundary: previous_boundary,
            to_boundary: boundary,
            diff: Engine.compare(previous_snapshot, snapshot)
          )
        end
        previous_boundary = boundary
        previous_snapshot = snapshot
      end
      [steps, root_snapshots, previous_snapshot]
    end

    #: (Array[untyped], Hash[Array[untyped], RecordSnapshot?], Array[ActivityStep]) -> Analysis
    def build_analysis(root_versions, root_snapshots, activity_steps)
      snapshots = root_versions.map do |version|
        root_snapshots.fetch(version_key(version))
      end
      Analysis.new(
        diff: Engine.compare(snapshots.first, snapshots.last),
        timeline: build_root_steps(root_versions, snapshots),
        activity_timeline: activity_steps.freeze
      )
    end

    #: (Array[untyped], Array[RecordSnapshot?]) -> Array[Step]
    def build_root_steps(root_versions, snapshots)
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
