# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Checks the recorded sequence itself, before any question of association
  # setup: whether the versions can be ordered at all, and whether timestamps
  # they share hide changes from a path PT-AT reads.
  class VersionSequenceDiagnostics
    #: (untyped, untyped, ?fallback_selected: bool) -> void
    def initialize(from_version, to_version, fallback_selected: false)
      @from_version = from_version
      @to_version = to_version
      @fallback_selected = fallback_selected
    end

    # The read runs in a savepoint, so that a query that fails here leaves a
    # snapshot transaction around it usable: PostgreSQL refuses every later
    # statement of a transaction once one has failed.
    #: () -> Array[DiagnosticIssue]
    def call
      versions = @from_version.class.transaction(requires_new: true) { ordered_range_versions }
      issues = [] #: Array[DiagnosticIssue?]
      issues << unorderable(versions)
      issues << tied_timestamps(versions) if @fallback_selected
      issues.compact
    rescue StandardError
      []
    end

    private

    # @rbs @from_version: untyped
    # @rbs @to_version: untyped
    # @rbs @fallback_selected: bool

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

    # Loaded history orders versions that share a timestamp by id, but PT-AT
    # places association changes by timestamp alone, so a path it reads loses
    # any change between such a pair. Unlike an unorderable sequence this is
    # not always wrong: if nothing that path reaches changed between them the
    # result is correct, and the gem cannot tell which it is, because not
    # seeing the change is the symptom. So it warns.
    #: (Array[untyped]) -> DiagnosticIssue?
    def tied_timestamps(versions)
      pair = Support.tied_timestamp_pair(versions)
      return unless pair

      left, right = pair
      DiagnosticIssue.new(
        severity: :warning,
        code: :tied_version_timestamps,
        message: "versions #{left.id.inspect} and #{right.id.inspect} share the timestamp " \
                 "#{left.created_at.inspect}, and an association requested here is read with " \
                 'PT-AT, which places association changes by timestamp alone, so a change ' \
                 'between them can be missed; record versions at sub-second precision to ' \
                 'separate them',
        version_id: left.id
      )
    end

    #: () -> Array[untyped]
    def ordered_range_versions
      range = time_range
      return [] unless range

      @from_version.class
                   .where(item_type: @from_version.item_type, item_id: @from_version.item_id)
                   .where(created_at: range)
                   .to_a
                   .sort_by { |version| Support.chronological_version_key(version) }
    end

    # Between the two versions, in either order, or from the one version on
    # when the other endpoint is the current record. A version that recorded
    # no time bounds nothing.
    #: () -> Range[untyped]?
    def time_range
      from = @from_version.created_at
      return from && (from..) unless @to_version

      bounds = [from, @to_version.created_at].compact.sort
      bounds.first..bounds.last if bounds.length == 2
    end
  end
end
