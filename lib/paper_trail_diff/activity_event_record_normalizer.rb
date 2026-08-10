# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Normalizes one event record with the historical reader for its boundary.
  class ActivityEventRecordNormalizer
    #: (?association_reader: untyped) -> void
    def initialize(association_reader: nil)
      @association_reader = association_reader || method(:historical_reader)
    end

    #: (untyped, reflection: untyped, subtree: AssociationTree, path: String, normalizer: SnapshotNormalizer, root_endpoint: untyped, context_endpoint: untyped) -> RecordSnapshot?
    def call( # rubocop:disable Metrics/ParameterLists
      record,
      reflection:,
      subtree:,
      path:,
      normalizer:,
      root_endpoint:,
      context_endpoint:
    )
      boundary = Endpoint.version?(root_endpoint) ? root_endpoint : context_endpoint
      reifier = @association_reader.call(context_endpoint, habtm_version: boundary)
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

    #: (untyped, habtm_version: untyped) -> HistoricalAssociationReifier
    def historical_reader(context_endpoint, habtm_version:)
      HistoricalAssociationReifier.new(context_endpoint, habtm_version: habtm_version)
    end
  end
end
