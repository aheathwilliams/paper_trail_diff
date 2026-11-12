# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Answers where a range of versions really starts: where the transactions
  # of its roots' first versions began (`range_start`).
  #
  # PT-AT reads a root's associations at the start of the transaction of the
  # root version it reifies, so a range that starts at a version starts
  # before whatever that version's transaction saved earlier. A wall-clock
  # window does not move: it reports the transactions that end inside it
  # (see TransactionEnds and CrossingTransactions).
  module TransactionCut
    # A range starting at a version starts before that version's transaction,
    # as PT-AT reads associations there. A version saved earlier in the same
    # transaction, such as the child update behind a `touch: true` parent
    # version, can be recorded before the start, so the start moves back to
    # where each root's first transaction in the range began. History loaded
    # from the start alone would read that child after its change.
    #: (Array[untyped], untyped) -> untyped
    def self.range_start(root_versions, start_at)
      began = opening_versions(root_versions, start_at)
              .each_slice(Support::IDS_PER_STATEMENT).map do |slice|
        transaction_start(slice, start_at)
      end
      [start_at, *began.compact].min
    end

    # Each root's first version at or after the start, where a transaction
    # saved it.
    #: (Array[untyped], untyped) -> Array[untyped]
    def self.opening_versions(root_versions, start_at)
      return [] unless start_at

      root_versions.reject { |version| version.created_at < start_at }
                   .sort_by { |version| Support.chronological_version_key(version) }
                   .uniq { |version| Endpoint.identity(version) }
                   .select { |version| VersionBoundary.transaction_id(version) }
    end
    private_class_method :opening_versions

    # When the earliest of the transactions of these versions began. Of
    # transactions that share a number, only the one each version is in
    # counts (see TransactionAnchors).
    #: (Array[untyped], untyped) -> untyped
    def self.transaction_start(versions, start_at)
      version_class = versions.first.class
      numbers = versions.map { |version| VersionBoundary.transaction_id(version) }
      TransactionAnchors.continued(version_class.where(transaction_id: numbers), version_class,
                                   start_at, versions).minimum(:created_at)
    end
    private_class_method :transaction_start
  end
end
