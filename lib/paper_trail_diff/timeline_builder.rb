# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects and compares a chronological slice of a record's version history.
  class TimelineBuilder
    #: (untyped, from: untyped, to: untyped, snapshotter: untyped, ?within: untyped, ?versions: Array[untyped]?, ?version_scope: untyped, ?plan: RootVersionPlan?) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      record, from:, to:, snapshotter:, within: nil, versions: nil, version_scope: nil, plan: nil
    )
      @record = record
      @range = TimelineRange.new(
        record, from: from, to: to, within: within,
                versions: versions, version_scope: version_scope, plan: plan
      )
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
        timeline: steps,
        from_snapshot: first_snapshot,
        to_snapshot: last_snapshot
      )
    end

    private

    # @rbs @record: untyped
    # @rbs @range: TimelineRange
    # @rbs @snapshotter: untyped

    #: (RootVersionPlan) -> [Array[Step], RecordSnapshot?, RecordSnapshot?]
    def compare_history(plan)
      return empty_history if plan.empty?

      versions = plan.versions
      @snapshotter.prepare(@record, versions) if @snapshotter.respond_to?(:prepare)
      steps = plan.steps.map do |from_version, to_version|
        Step.new(
          from_version: from_version,
          to_version: to_version,
          diff: Engine.compare(@snapshotter.call(from_version), @snapshotter.call(to_version))
        )
      end.freeze
      [steps, @snapshotter.call(versions.first), @snapshotter.call(versions.last)]
    end

    #: () -> [Array[Step], nil, nil]
    def empty_history
      steps = [] #: Array[Step]
      [steps.freeze, nil, nil]
    end

    #: () -> RootVersionPlan
    def selected_versions
      @range.select_plan
    end
  end
end
