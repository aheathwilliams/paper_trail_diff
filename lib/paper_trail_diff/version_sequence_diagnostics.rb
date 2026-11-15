# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Checks the recorded sequence itself, before any question of association
  # setup: whether the versions can be ordered at all, and whether they are
  # dated in the order they were saved.
  class VersionSequenceDiagnostics
    #: (untyped, untyped) -> void
    def initialize(from_version, to_version)
      @from_version = from_version
      @to_version = to_version
    end

    # The read runs in a savepoint, so that a query that fails here leaves a
    # snapshot transaction around it usable: PostgreSQL refuses every later
    # statement of a transaction once one has failed.
    #: () -> Array[DiagnosticIssue]
    def call
      versions = @from_version.class.transaction(requires_new: true) { ordered_range_versions }
      issues = [] #: Array[DiagnosticIssue?]
      issues << unorderable(versions)
      issues << inverted(versions)
      issues.compact
    rescue StandardError
      []
    end

    private

    # @rbs @from_version: untyped
    # @rbs @to_version: untyped

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

    # Versions are read in time order, and ids that count up in one table say
    # which was saved first. A later version dated earlier was usually dated
    # by PaperTrail at an `updated_at` the application set itself, and the
    # history then reads it before the change it followed: an update dated
    # before the record's create reads as the record deleted and created
    # again. A time can also be right and the id wrong, as for versions
    # imported from elsewhere, so this warns rather than refuses.
    #: (Array[untyped]) -> DiagnosticIssue?
    def inverted(versions)
      pair = versions.each_cons(2).find do |left, right|
        Support.orderable_tie?(left, right) && Integer(right.id) < Integer(left.id)
      end
      return unless pair

      saved_last, saved_first = pair
      DiagnosticIssue.new(
        severity: :warning, code: :inverted_version_order,
        message: inverted_message(saved_first, saved_last), version_id: saved_last.id
      )
    end

    #: (untyped, untyped) -> String
    def inverted_message(saved_first, saved_last)
      "versions #{saved_first.id.inspect} and #{saved_last.id.inspect} were saved in that " \
        'order but are dated the other way round, at ' \
        "#{saved_first.created_at.inspect} and #{saved_last.created_at.inspect}, and history " \
        'reads them in time order; if a save set updated_at itself, which PaperTrail then ' \
        'dates its version at, set has_paper_trail synchronize_version_creation_timestamp: ' \
        'false and correct the stored created_at'
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
