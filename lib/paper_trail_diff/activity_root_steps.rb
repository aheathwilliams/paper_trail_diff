# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Root checkpoint steps recovered from the snapshots an activity pass retained,
  # so a combined result does not reconstruct the same boundaries twice.
  module ActivityRootSteps
    module_function

    # A window closing on current state ends at the live record, which no
    # version-keyed snapshot can supply, so that endpoint is passed in. A plan
    # that replays versions a filter left out reports the steps of the ones it
    # kept, as `timeline` does.
    #: (RootVersionPlan, Hash[Array[untyped], RecordSnapshot?], ?closing_snapshot: RecordSnapshot?, ?captured_at: untyped) -> Array[Step]
    def call(plan, root_snapshots, closing_snapshot: nil, captured_at: nil)
      plan.steps.select { |from, _to| plan.mutation?(from) }.map do |from_endpoint, to_endpoint|
        Step.new(
          from_version: from_endpoint,
          to_version: to_endpoint,
          captured_at: captured_at,
          diff: Engine.compare(
            root_snapshots[Support.row_key(from_endpoint)],
            snapshot_for(to_endpoint, root_snapshots, closing_snapshot)
          )
        )
      end.freeze
    end

    #: (untyped, Hash[Array[untyped], RecordSnapshot?], RecordSnapshot?) -> RecordSnapshot?
    def snapshot_for(endpoint, root_snapshots, closing_snapshot)
      return closing_snapshot if Endpoint.record?(endpoint)

      root_snapshots[Support.row_key(endpoint)]
    end
  end
end
