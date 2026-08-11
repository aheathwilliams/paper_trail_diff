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

    #: (?context_required: bool) -> Array[untyped]
    def select(context_required: false)
      select_plan(context_required: context_required).versions
    end

    #: (?context_required: bool) -> RootVersionPlan
    def select_plan(context_required: false)
      relation = versions_relation
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

    #: () -> untyped
    def versions_relation
      association_name = @record.class.versions_association_name
      @record.public_send(association_name)
    rescue NoMethodError => e
      message = 'record does not expose a PaperTrail version history'
      raise InvalidTimelineRangeError, message, cause: e
    end

    #: (untyped) -> untyped
    def trailing_version(relation)
      @time_range.trailing_scope(relation).reorder(created_at: :asc, id: :asc).first
    end

    #: (Array[untyped]) -> Array[untyped]
    def ordered(versions)
      versions.sort_by { |version| Support.chronological_version_key(version) }
    end
  end
end
