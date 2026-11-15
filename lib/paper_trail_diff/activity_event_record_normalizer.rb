# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Normalizes the state an event left, with its selected associations as
  # the event's boundary reads them.
  class ActivityEventRecordNormalizer
    #: (member_snapshot: untyped) -> void
    def initialize(member_snapshot:)
      @member_snapshot = member_snapshot
    end

    #: (PreparedRecordState, reflection: untyped, subtree: AssociationTree, path: String, normalizer: SnapshotNormalizer, context_endpoint: untyped) -> RecordSnapshot
    def call( # rubocop:disable Metrics/ParameterLists
      state,
      reflection:,
      subtree:,
      path:,
      normalizer:,
      context_endpoint:
    )
      if subtree.empty?
        return normalizer.from_state(state, tree: subtree, path: path, incoming: reflection)
      end

      @member_snapshot.call(state, context_endpoint, tree: subtree, path: path,
                                                     incoming: reflection, normalizer: normalizer)
    end

    # @rbs @member_snapshot: untyped
  end
end
