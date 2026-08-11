# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects in-range root versions plus one later reconstruction boundary.
  class TimeVersionRange
    #: (untyped, time_range: TimeRange, ?version_scope: untyped) -> void
    def initialize(record, time_range:, version_scope: nil)
      @record = record
      @time_range = time_range
      @version_scope = version_scope
    end

    #: (?context_required: bool) -> Array[untyped]
    def select(context_required: false)
      select_with_context(context_required: context_required).first
    end

    # The second value is the version present only to reveal the last selected
    # mutation, which a caller reporting mutations must not treat as one.
    #: (?context_required: bool) -> [Array[untyped], untyped]
    def select_with_context(context_required: false)
      relation = versions_relation
      in_range = ordered(@time_range.scope(relation).to_a)
      RootVersionSelection.new(
        in_range: in_range,
        selected: VersionScopeFilter.new(@version_scope).call(@time_range.scope(relation),
                                                              in_range),
        after_range: trailing_version(relation),
        windowed: true,
        context_required: context_required
      ).call
    end

    private

    # @rbs @record: untyped
    # @rbs @time_range: TimeRange
    # @rbs @version_scope: untyped

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
