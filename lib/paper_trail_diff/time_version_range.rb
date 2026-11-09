# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects in-range root versions plus one later reconstruction boundary.
  class TimeVersionRange
    #: (untyped, time_range: TimeRange, version_scope: untyped, live_endpoint: untyped) -> void
    def initialize(record, time_range:, version_scope:, live_endpoint:)
      @record = record
      @time_range = time_range
      @version_scope = version_scope
      @live_endpoint = live_endpoint
    end

    #: (context_required: bool, whole: bool) -> RootVersionPlan
    def select_plan(context_required:, whole:)
      relation = Endpoint.versions(@record)
      in_range = @time_range.scope(relation)
      RootVersionSelection.new(
        in_range: in_range,
        selected: VersionScopeFilter.new(@version_scope).call(@time_range.scope(relation),
                                                              in_range),
        after_range: trailing_version(relation),
        windowed: true,
        context_required: context_required,
        live_endpoint: @live_endpoint,
        whole: whole
      ).call
    end

    private

    # @rbs @record: untyped
    # @rbs @time_range: TimeRange
    # @rbs @version_scope: untyped
    # @rbs @live_endpoint: untyped

    # Two are read, so that a tie for first that ids cannot order raises, as
    # a tie inside the range does, instead of the lower id choosing the state
    # the range ends in.
    #: (untyped) -> untyped
    def trailing_version(relation)
      candidates = VersionQuery.chronological(@time_range.trailing_scope(relation)).limit(2).to_a
      Support.earliest_version(candidates)
    end
  end
end
