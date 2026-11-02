# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Which events a `version_scope:` reports in activity on associations.
  #
  # PT-AT reads a transaction's records as they stood before it began, so the
  # changes a transaction saved surface together in its last step rather than
  # each in the step of its own version (see ActivityTransactionGrouper). No
  # step inside a transaction can be credited to one version of it, and
  # leaving one out would lose the changes it carried. A transaction is
  # therefore reported whole when the filter keeps any version saved in it, of
  # whichever record, and a version saved outside a transaction when the
  # filter keeps that version. Both are answered from the version tables, so
  # every window and every way of asking reads the same transaction alike.
  #
  # One filter serves a request. It reads the answers for each history once,
  # in one statement per version table and 500 transactions or versions, and
  # the roots a batch prepared together share them.
  class ActivityScopeFilter
    #: (untyped) -> void
    def initialize(scope)
      @scope = scope
      @transactions = {} #: Hash[Array[untyped], bool]
      @versions = {} #: Hash[Array[untyped], bool]
      @histories = Set.new #: Set[PreparedHistory]
    end

    # Reads the answers for every version `history` holds, once for each
    # history, and for those of `versions` it does not hold.
    #: (PreparedHistory?, Array[untyped]) -> void
    def prepare(history, versions)
      read(history.versions) if history && @histories.add?(history)
      read(versions)
    end

    # Whether the filter keeps a version of `version`'s transaction, or
    # `version` itself when it was saved outside one. `prepare` reads it first.
    #: (untyped) -> bool
    def kept?(version)
      transaction = ActivityTransactionGroups.transaction_key(version)
      return @transactions.fetch(transaction) if transaction

      @versions.fetch([version.class.name, version.id])
    end

    private

    # @rbs @scope: untyped
    # @rbs @transactions: Hash[Array[untyped], bool]
    # @rbs @versions: Hash[Array[untyped], bool]
    # @rbs @histories: Set[PreparedHistory]

    #: (Array[untyped]) -> void
    def read(versions)
      versions.group_by(&:class).each do |version_class, group|
        name = version_class.name
        saved = group.group_by { |version| VersionBoundary.transaction_id(version) }
        loose = saved.delete(nil) || []
        read_kept(version_class, @transactions, name, saved.keys, :transaction_id)
        read_kept(version_class, @versions, name, loose.map(&:id), :id)
      end
    end

    # Records which of the distinct `values` of `column` the filter keeps
    # versions with.
    #: (untyped, Hash[Array[untyped], bool], String, Array[untyped], Symbol) -> void
    def read_kept(version_class, answers, name, values, column)
      values.reject { |value| answers.key?([name, value]) }
            .each_slice(Support::IDS_PER_STATEMENT) do |slice|
        kept = @scope.call(version_class.where(column => slice)).pluck(column)
        slice.each { |value| answers[[name, value]] = false }
        kept.each { |value| answers[[name, value]] = true }
      end
    end
  end
end
