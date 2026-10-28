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

      unless orderable_tie?(candidate, boundary)
        raise AmbiguousVersionOrderError, Support.ambiguous_message([boundary, candidate])
      end

      Support.compare_versions(candidate, boundary) >= 0
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

    #: (untyped, untyped) -> bool
    def orderable_tie?(left, right)
      left.class.table_name == right.class.table_name &&
        Support.sequential_id?(left.id) && Support.sequential_id?(right.id)
    end
    private_class_method :orderable_tie?
  end
end
