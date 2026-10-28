# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects in-range root versions plus one later reconstruction boundary.
  class TimeVersionRange
    #: (untyped, time_range: TimeRange, ?version_scope: untyped, ?live_endpoint: untyped) -> void
    def initialize(record, time_range:, version_scope: nil, live_endpoint: nil)
      @record = record
      @time_range = time_range
      @version_scope = version_scope
      @live_endpoint = live_endpoint
    end

    #: (?context_required: bool) -> RootVersionPlan
    def select_plan(context_required: false)
      relation = Endpoint.versions(@record)
      in_range = ordered(@time_range.scope(relation).to_a)
      RootVersionSelection.new(
        in_range: in_range,
        selected: VersionScopeFilter.new(@version_scope).call(@time_range.scope(relation),
                                                              in_range),
        after_range: trailing_version(relation),
        windowed: true,
        context_required: context_required,
        filtered: !@version_scope.nil?,
        live_endpoint: @live_endpoint
      ).call
    end

    private

    # @rbs @record: untyped
    # @rbs @time_range: TimeRange
    # @rbs @version_scope: untyped
    # @rbs @live_endpoint: untyped

    #: (untyped) -> untyped
    def trailing_version(relation)
      VersionQuery.chronological(@time_range.trailing_scope(relation)).first
    end

    #: (Array[untyped]) -> Array[untyped]
    def ordered(versions)
      Support.chronological_sort(versions)
    end
  end
end
