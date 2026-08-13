# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Checks the recorded sequence itself, before any question of association
  # setup: whether the versions can be ordered at all, and whether timestamps
  # they share hide changes that ordering alone cannot recover.
  class VersionSequenceDiagnostics
    #: (untyped, untyped, ?associations_selected: bool) -> void
    def initialize(from_version, to_version, associations_selected: false)
      @from_version = from_version
      @to_version = to_version
      @associations_selected = associations_selected
    end

    #: () -> Array[DiagnosticIssue]
    def call
      versions = ordered_range_versions
      issues = [] #: Array[DiagnosticIssue?]
      issues << unorderable(versions)
      issues << tied_timestamps(versions) if @associations_selected
      issues.compact
    rescue StandardError
      []
    end

    private

    # @rbs @from_version: untyped
    # @rbs @to_version: untyped
    # @rbs @associations_selected: bool

    # Ordering falls back to the id when timestamps tie, which only recovers the
    # real sequence for ids that increase with insertion. Reported before a run
    # rather than after a wrong answer.
    #: (Array[untyped]) -> DiagnosticIssue?
    def unorderable(versions)
      pair = Support.ambiguous_pair(versions)
      return unless pair

      DiagnosticIssue.new(
        severity: :error,
        code: :ambiguous_version_order,
        message: Support.ambiguous_message(pair),
        version_id: pair.first.id
      )
    end

    # Association membership is recorded per version but resolved by timestamp,
    # so a tie hides any association change across that pair. Unlike an
    # unorderable sequence this is not always wrong: if nothing associated
    # changed between them the result is correct, and the gem cannot tell which
    # it is, because not seeing the change is the symptom. So it warns.
    #: (Array[untyped]) -> DiagnosticIssue?
    def tied_timestamps(versions)
      pair = Support.tied_timestamp_pair(versions)
      return unless pair

      left, right = pair
      DiagnosticIssue.new(
        severity: :warning,
        code: :tied_version_timestamps,
        message: "versions #{left.id.inspect} and #{right.id.inspect} share the timestamp " \
                 "#{left.created_at.inspect}, so association changes between them cannot " \
                 'be detected; record versions at sub-second precision to separate them',
        version_id: left.id
      )
    end

    #: () -> Array[untyped]
    def ordered_range_versions
      bounds = [@from_version.created_at, @to_version.created_at].compact.sort
      return [] unless bounds.length == 2

      @from_version.class
                   .where(item_type: @from_version.item_type, item_id: @from_version.item_id)
                   .where(created_at: bounds.first..bounds.last)
                   .to_a
                   .sort_by { |version| Support.chronological_version_key(version) }
    end
  end
end
