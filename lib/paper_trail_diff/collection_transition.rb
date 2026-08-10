# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # One collection mutation between structurally adjacent snapshots.
  class CollectionTransition
    attr_reader :before #: RecordSnapshot?
    attr_reader :after #: RecordSnapshot?

    # The origin is recorded by serial rather than by reference, because
    # holding it would retain every earlier snapshot at the same path for the
    # whole timeline.
    #: (from: AssociationSnapshot, before: RecordSnapshot?, after: RecordSnapshot?) -> void
    def initialize(from:, before:, after:)
      @from_serial = from.serial
      @before = before
      @after = after
      freeze
    end

    #: (AssociationSnapshot) -> bool
    def from?(association)
      @from_serial == association.serial
    end

    # @rbs @from_serial: Integer
  end
end
