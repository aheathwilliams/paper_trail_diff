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

    # The same row of the same version table. A record or instant is never a
    # version.
    #: (untyped, untyped) -> bool
    def self.same_version?(left, right)
      version_record?(left) && version_record?(right) &&
        left.class.table_name == right.class.table_name && left.id.to_s == right.id.to_s
    end
  end
end
