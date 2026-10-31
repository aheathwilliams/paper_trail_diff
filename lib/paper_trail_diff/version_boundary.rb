# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Places one version relative to another on the recorded timeline.
  module VersionBoundary
    module_function

    # Whether `candidate` was recorded at or after `boundary`. Versions sharing
    # a timestamp are ordered by id, which reflects insertion order only for
    # sequential ids in one version table; any other tie cannot be ordered, and
    # guessing would place a change on an arbitrary side of the boundary. A
    # bare instant has no position among same-time versions, so it keeps them.
    #: (untyped, untyped) -> bool
    def at_or_after?(candidate, boundary)
      tied = candidate.created_at == boundary.created_at
      return candidate.created_at > boundary.created_at unless tied
      return true unless version_record?(boundary)
      return true if same_version?(candidate, boundary)

      unless Support.orderable_tie?(candidate, boundary)
        raise AmbiguousVersionOrderError, Support.ambiguous_message([boundary, candidate])
      end

      Support.compare_versions(candidate, boundary) >= 0
    end

    # A range starting at a version starts before that version's transaction,
    # as PT-AT reads associations there. A version saved earlier in the same
    # transaction, such as the child update behind a `touch: true` parent
    # version, can be recorded before the start, so the start moves back to
    # the earliest version of each root's first transaction in the range.
    # History loaded from the start alone would read that child after its
    # change.
    #: (Array[untyped], untyped) -> untyped
    def transaction_start(root_versions, start_at)
      opening = opening_transactions(root_versions, start_at)
      return start_at if opening.empty?

      earliest = root_versions.first.class.where(transaction_id: opening).minimum(:created_at)
      earliest && earliest < start_at ? earliest : start_at
    end

    # The transaction of each root's first version at or after the start.
    #: (Array[untyped], untyped) -> Array[untyped]
    def opening_transactions(root_versions, start_at)
      return [] unless start_at

      root_versions.reject { |version| version.created_at < start_at }
                   .sort_by { |version| Support.chronological_version_key(version) }
                   .uniq { |version| [version.item_type.to_s, version.item_id.to_s] }
                   .filter_map { |version| transaction_id(version) }.uniq
    end
    private_class_method :opening_transactions

    # A custom version class need not carry the column, and PaperTrail leaves
    # it nil outside a transaction. Both read as "no transaction here", which
    # groups with nothing.
    #: (untyped) -> untyped
    def transaction_id(version)
      version.transaction_id if version.respond_to?(:transaction_id)
    end

    #: (untyped) -> bool
    def version_record?(value)
      value.respond_to?(:id) && value.respond_to?(:item_type) &&
        value.class.respond_to?(:table_name)
    end
    private_class_method :version_record?

    #: (untyped, untyped) -> bool
    def same_version?(left, right)
      left.class.table_name == right.class.table_name && left.id.to_s == right.id.to_s
    end
    private_class_method :same_version?
  end
end
