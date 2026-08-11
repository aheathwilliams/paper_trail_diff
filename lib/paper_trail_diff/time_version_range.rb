# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects in-range root versions plus one later reconstruction boundary.
  class TimeVersionRange
    #: (untyped, time_range: TimeRange) -> void
    def initialize(record, time_range:)
      @record = record
      @time_range = time_range
    end

    #: (?context_required: bool) -> Array[untyped]
    def select(context_required: false)
      relation = versions_relation
      selected = ordered(@time_range.scope(relation).to_a)
      empty = [] #: Array[untyped]
      return empty.freeze if selected.empty? && !context_required

      trailing = trailing_version(relation)
      unless trailing
        return selected.freeze if terminal_destroy?(selected)

        message = 'time range requires a later root version to reconstruct its final change'
        raise IncompleteTimeRangeError, message
      end

      (selected + [trailing]).freeze
    end

    private

    # @rbs @record: untyped
    # @rbs @time_range: TimeRange

    #: () -> untyped
    def versions_relation
      association_name = @record.class.versions_association_name
      @record.public_send(association_name)
    rescue NoMethodError => e
      message = 'record does not expose a PaperTrail version history'
      raise InvalidTimelineRangeError, message, cause: e
    end

    # A window closing on the record's own destruction needs no later version:
    # the destroy reveals the preceding mutation and nothing can follow it, so
    # demanding a checkpoint that can never be written would reject the range
    # permanently.
    #: (Array[untyped]) -> bool
    def terminal_destroy?(versions)
      versions.last&.event.to_s == 'destroy'
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
