# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Normalizes one event record with the historical reader for its boundary.
  class ActivityEventRecordNormalizer
    #: (?association_reader: untyped) -> void
    def initialize(association_reader: nil)
      @association_reader = association_reader || method(:historical_reader)
    end

    #: (untyped, reflection: untyped, subtree: AssociationTree, path: String, normalizer: SnapshotNormalizer, context_endpoint: untyped) -> RecordSnapshot?
    def call( # rubocop:disable Metrics/ParameterLists
      record,
      reflection:,
      subtree:,
      path:,
      normalizer:,
      context_endpoint:
    )
      if record.is_a?(PreparedRecordState)
        return normalizer.from_state(record, tree: subtree, path: path, incoming: reflection)
      end

      reifier = @association_reader.call(context_endpoint)
      normalizer.call_child(
        record,
        tree: subtree,
        path: path,
        incoming: reflection,
        reifier: reifier
      )
    end

    private

    # @rbs @association_reader: untyped

    #: (untyped) -> HistoricalAssociationReifier
    def historical_reader(context_endpoint)
      HistoricalAssociationReifier.new(context_endpoint)
    end
  end
end
