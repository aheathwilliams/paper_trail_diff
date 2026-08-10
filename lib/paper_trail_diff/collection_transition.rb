# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # One collection mutation between structurally adjacent snapshots.
  class CollectionTransition
    attr_reader :before #: RecordSnapshot?
    attr_reader :after #: RecordSnapshot?

    #: (from: AssociationSnapshot, before: RecordSnapshot?, after: RecordSnapshot?) -> void
    def initialize(from:, before:, after:)
      @from_object_id = from.object_id
      @before = before
      @after = after
      freeze
    end

    #: (AssociationSnapshot) -> bool
    def from?(association)
      @from_object_id == association.object_id
    end

    # @rbs @from_object_id: Integer
  end
end
