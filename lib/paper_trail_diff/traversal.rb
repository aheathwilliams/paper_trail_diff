# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Coordinates root lifecycle, scalar, and association traversal.
  class DiffTraversal < TraversalEmitter
    #: (Diff, ^(TraversalEntry) -> void) -> void
    def initialize(diff, receiver)
      super(receiver)
      @diff = diff
      @associations = AssociationDiffTraversal.new(receiver)
      @snapshots = SnapshotTraversal.new(receiver)
    end

    #: () -> void
    def call
      walk_presence_change
      @associations.attributes(
        @diff.attributes,
        association_path: [],
        record_path: [],
        association_kind: nil
      )
      @associations.call(@diff.associations, association_path: [], record_path: [])
    end

    private

    # @rbs @diff: Diff
    # @rbs @associations: AssociationDiffTraversal
    # @rbs @snapshots: SnapshotTraversal

    #: () -> void
    def walk_presence_change
      change = @diff.record_presence_change
      return unless change

      emit(
        kind: :record_presence_changed,
        context: :change,
        association_path: [],
        record_path: [],
        value: change
      )
      walk_presence_snapshot(change.from, :before)
      walk_presence_snapshot(change.to, :after)
    end

    #: (RecordSnapshot?, traversal_state) -> void
    def walk_presence_snapshot(snapshot, state)
      return unless snapshot

      @snapshots.call(snapshot, association_path: [], record_path: [], state: state)
    end
  end
  private_constant :DiffTraversal

  # The complete structured difference between two normalized endpoints.
  class Diff
    # Walks semantic changes and the nested state carried by added or removed records.
    # @rbs () { (TraversalEntry) -> void } -> Diff
    #    | () -> Enumerator[TraversalEntry, Diff]
    def each_entry(&receiver)
      return enum_for(:each_entry) unless receiver

      DiffTraversal.new(self, receiver).call
      self
    end

    # Walks only semantic changes, excluding snapshot state included for context.
    # @rbs () { (TraversalEntry) -> void } -> Diff
    #    | () -> Enumerator[TraversalEntry, Diff]
    def each_change(&receiver)
      return enum_for(:each_change) unless receiver

      each_entry { |entry| receiver.call(entry) if entry.change? }
      self
    end
  end
end
