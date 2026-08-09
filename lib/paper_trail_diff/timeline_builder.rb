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
      steps, = compare_history(selected_versions)
      steps
    end

    #: () -> Analysis
    def analyze
      steps, first_snapshot, last_snapshot = compare_history(selected_versions)
      Analysis.new(
        diff: Engine.compare(first_snapshot, last_snapshot),
        timeline: steps
      )
    end

    private

    # @rbs @record: untyped
    # @rbs @from: untyped
    # @rbs @to: untyped
    # @rbs @snapshotter: untyped

    #: (Array[untyped]) -> [Array[Step], RecordSnapshot?, RecordSnapshot?]
    def compare_history(versions)
      @snapshotter.prepare(@record, versions) if @snapshotter.respond_to?(:prepare)
      first_snapshot = @snapshotter.call(versions.first)
      previous_snapshot = first_snapshot
      steps = versions.each_cons(2).map do |from_version, to_version|
        current_snapshot = @snapshotter.call(to_version)
        step = Step.new(
          from_version: from_version,
          to_version: to_version,
          diff: Engine.compare(previous_snapshot, current_snapshot)
        )
        previous_snapshot = current_snapshot
        step
      end.freeze
      [steps, first_snapshot, previous_snapshot]
    end

    #: () -> Array[untyped]
    def selected_versions
      VersionRange.new(@record, from: @from, to: @to).select
    end
  end
end
