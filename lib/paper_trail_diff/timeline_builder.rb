# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects and compares a chronological slice of a record's version history.
  class TimelineBuilder
    #: (untyped, from: untyped, to: untyped, snapshotter: untyped) -> void
    def initialize(record, from:, to:, snapshotter:)
      @record = record
      @from = from
      @to = to
      @snapshotter = snapshotter
    end

    #: () -> Array[Step]
    def build
      versions, snapshots = normalized_history
      build_steps(versions, snapshots)
    end

    #: () -> Analysis
    def analyze
      versions, snapshots = normalized_history
      Analysis.new(
        diff: Engine.compare(snapshots.first, snapshots.last),
        timeline: build_steps(versions, snapshots)
      )
    end

    private

    # @rbs @record: untyped
    # @rbs @from: untyped
    # @rbs @to: untyped
    # @rbs @snapshotter: untyped

    #: (Array[untyped], Array[RecordSnapshot?]) -> Array[Step]
    def build_steps(versions, snapshots)
      versions.each_cons(2).with_index.map do |version_pair, index|
        Step.new(
          from_version: version_pair.first,
          to_version: version_pair.last,
          diff: Engine.compare(snapshots.fetch(index), snapshots.fetch(index + 1))
        )
      end.freeze
    end

    #: () -> [Array[untyped], Array[RecordSnapshot?]]
    def normalized_history
      versions = selected_versions
      [versions, versions.map { |version| @snapshotter.call(version) }]
    end

    #: () -> Array[untyped]
    def selected_versions
      VersionRange.new(@record, from: @from, to: @to).select
    end
  end
end
