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
      versions = collect_versions(root_versions)
      snapshots = versions.map { |version| snapshot_at(root_versions, version) }
      build_steps(versions.map { |version| ActivityBoundary.from_version(version) }, snapshots)
    end

    #: () -> Array[ActivityStep]
    def build_to_current
      validate_current_range!
      current_snapshot, captured_at = capture_current
      versions, snapshots = history_to_current(captured_at)
      boundaries = boundaries_to_current(versions, captured_at)
      build_steps(boundaries, snapshots + [current_snapshot])
    end

    #: () -> [RecordSnapshot?, untyped]
    def capture_current
      [@snapshotter.call(@to, @to), Time.now.utc]
    end

    #: (untyped) -> [Array[untyped], Array[RecordSnapshot?]]
    def history_to_current(captured_at)
      root_versions = VersionRange.new(@record, from: @from, to: @from).select_through_latest
      versions = collect_versions(root_versions, range_end: captured_at)
      snapshots = versions.map { |version| snapshot_at(root_versions, version, current: @to) }
      [versions, snapshots]
    end

    #: (Array[untyped], untyped) -> Array[ActivityBoundary]
    def boundaries_to_current(versions, captured_at)
      boundaries = versions.map { |version| ActivityBoundary.from_version(version) }
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

    #: (Array[untyped], ?range_end: untyped) -> Array[untyped]
    def collect_versions(root_versions, range_end: root_versions.last)
      ActivityVersionCollector.new(
        @record,
        root_versions: root_versions,
        tree: @tree,
        traversal: AssociationTraversal.new(@tree),
        range_end: range_end
      ).call
    end

    #: (Array[untyped], untyped, ?current: untyped) -> RecordSnapshot?
    def snapshot_at(root_versions, activity_version, current: nil)
      root_version = root_anchor(root_versions, activity_version)
      root_endpoint = root_version || current || root_versions.last
      @snapshotter.call(root_endpoint, activity_version)
    end

    #: (Array[untyped], untyped) -> untyped
    def root_anchor(root_versions, activity_version)
      root_versions.find do |root_version|
        Support.compare_versions(root_version, activity_version) >= 0
      end
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
