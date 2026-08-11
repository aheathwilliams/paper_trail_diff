# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Root checkpoint steps recovered from the snapshots an activity pass retained,
  # so a combined result does not reconstruct the same boundaries twice.
  module ActivityRootSteps
    module_function

    #: (RootVersionPlan, Hash[Array[untyped], RecordSnapshot?]) -> Array[Step]
    def call(plan, root_snapshots)
      plan.steps.map do |from_version, to_version|
        Step.new(
          from_version: from_version,
          to_version: to_version,
          diff: Engine.compare(
            root_snapshots[version_key(from_version)],
            root_snapshots[version_key(to_version)]
          )
        )
      end.freeze
    end

    #: (untyped) -> Array[untyped]
    def version_key(version)
      [version.class.name, version.id]
    end
  end
end
