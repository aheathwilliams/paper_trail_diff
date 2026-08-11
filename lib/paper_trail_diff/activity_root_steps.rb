# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Root checkpoint steps recovered from the snapshots an activity pass retained,
  # so a combined result does not reconstruct the same boundaries twice.
  module ActivityRootSteps
    module_function

    #: (Array[untyped], Hash[Array[untyped], RecordSnapshot?]) -> Array[Step]
    def call(root_versions, root_snapshots)
      snapshots = root_versions.map { |version| root_snapshots.fetch(version_key(version)) }
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
