# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Places one version relative to another on the recorded timeline.
  module VersionBoundary
    @transactional = {} #: Hash[untyped, bool]
    @version_records = {} #: Hash[untyped, bool]

    # Whether `candidate` was recorded at or after `boundary`. Versions sharing
    # a timestamp are ordered by id, which reflects insertion order only for
    # sequential ids in one version table; any other tie cannot be ordered, and
    # guessing would place a change on an arbitrary side of the boundary. A
    # bare instant has no position among same-time versions, so it keeps them.
    # `time` and `boundary_time` are when each was recorded, which a caller
    # placing many versions against one boundary reads once.
    #: (untyped, untyped, ?time: untyped, ?boundary_time: untyped) -> bool
    def self.at_or_after?(candidate, boundary, time: candidate.created_at,
                          boundary_time: boundary.created_at)
      return time > boundary_time unless time == boundary_time
      return true unless version_record?(boundary)
      return true if same_version?(candidate, boundary)

      unless Support.orderable_tie?(candidate, boundary)
        raise AmbiguousVersionOrderError, Support.ambiguous_message([boundary, candidate])
      end

      # Different rows of one table, so one id comes after the other.
      Support.compare_versions(candidate, boundary).positive?
    end

    # A range starting at a version starts before that version's transaction,
    # as PT-AT reads associations there. A version saved earlier in the same
    # transaction, such as the child update behind a `touch: true` parent
    # version, can be recorded before the start, so the start moves back to
    # the earliest version of each root's first transaction in the range.
    # History loaded from the start alone would read that child after its
    # change. The transactions go 500 to a statement.
    #: (Array[untyped], untyped) -> untyped
    def self.transaction_start(root_versions, start_at)
      earliest = opening_versions(root_versions, start_at)
                 .each_slice(Support::IDS_PER_STATEMENT).filter_map do |slice|
        began(slice, start_at)
      end.min
      earliest && earliest < start_at ? earliest : start_at
    end

    # When the earliest of these versions' transactions began. Another
    # version table can number a transaction as this one numbered an earlier
    # one, so only the versions of the transaction each of these is in are
    # read (see TransactionAnchors).
    #: (Array[untyped], untyped) -> untyped
    def self.began(versions, start_at)
      version_class = versions.first.class
      saved = version_class.where(transaction_id: versions.map do |version|
        transaction_id(version)
      end)
      TransactionAnchors.continued(saved, version_class, TransactionCut::Edge.new(start_at, false),
                                   versions.map(&:id)).minimum(:created_at)
    end
    private_class_method :began

    # Each root's first version at or after the start, where a transaction
    # saved it.
    #: (Array[untyped], untyped) -> Array[untyped]
    def self.opening_versions(root_versions, start_at)
      return [] unless start_at

      root_versions.reject { |version| version.created_at < start_at }
                   .sort_by { |version| Support.chronological_version_key(version) }
                   .uniq { |version| Endpoint.identity(version) }
                   .select { |version| transaction_id(version) }
    end
    private_class_method :opening_versions

    # A custom version class need not carry the column, and PaperTrail leaves
    # it nil outside a transaction. Both read as "no transaction here", which
    # groups with nothing.
    #: (untyped) -> untyped
    def self.transaction_id(version)
      version.transaction_id if transactional?(version)
    end

    # Answered once for each Active Record class (see Support.per_model).
    #: (untyped) -> bool
    def self.transactional?(version)
      known = @transactional #: Hash[untyped, bool]
      Support.per_model(known, version) { |value| value.respond_to?(:transaction_id) }
    end
    private_class_method :transactional?

    # Answered once for each Active Record class, as `transactional?` is.
    #: (untyped) -> bool
    def self.version_record?(value)
      known = @version_records #: Hash[untyped, bool]
      Support.per_model(known, value) do |candidate|
        candidate.respond_to?(:id) && candidate.respond_to?(:item_type) &&
          candidate.class.respond_to?(:table_name)
      end
    end
    private_class_method :version_record?

    # The same row of the same version table. A record or instant is never a
    # version.
    #: (untyped, untyped) -> bool
    def self.same_version?(left, right)
      version_record?(left) && version_record?(right) &&
        left.class.table_name == right.class.table_name && left.id.to_s == right.id.to_s
    end
  end
end
