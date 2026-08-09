# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Walks nested singular and collection association differences.
  class AssociationDiffTraversal < TraversalEmitter
    #: (^(TraversalEntry) -> void) -> void
    def initialize(receiver)
      super
      @snapshots = SnapshotTraversal.new(receiver)
    end

    #: (association_diffs, association_path: traversal_association_path, record_path: traversal_record_path) -> void
    def call(associations, association_path:, record_path:)
      associations.each do |name, association|
        child_path = association_path + [name]
        walk_association(association, child_path, record_path)
      end
    end

    #: (Hash[String, ValueChange], association_path: traversal_association_path, record_path: traversal_record_path, association_kind: Symbol?) -> void
    def attributes(changes, association_path:, record_path:, association_kind:)
      changes.each do |name, change|
        emit_attribute(name, change, association_path, record_path, association_kind)
      end
    end

    private

    # @rbs @snapshots: SnapshotTraversal

    #: (association_diff, traversal_association_path, traversal_record_path) -> void
    def walk_association(association, association_path, record_path)
      if association.is_a?(CollectionAssociationDiff)
        walk_collection(association, association_path, record_path)
      else
        walk_to_one(association, association_path, record_path)
      end
    end

    #: (String, ValueChange, traversal_association_path, traversal_record_path, Symbol?) -> void
    def emit_attribute(name, change, association_path, record_path, association_kind)
      emit(
        kind: :attribute_changed,
        context: :change,
        association_path: association_path,
        record_path: record_path,
        association_kind: association_kind,
        attribute: name,
        value: change
      )
    end

    #: (CollectionAssociationDiff, traversal_association_path, traversal_record_path) -> void
    def walk_collection(association, association_path, record_path)
      walk_memberships(
        association.added, :record_added, :after,
        association, association_path, record_path
      )
      walk_memberships(
        association.removed, :record_removed, :before,
        association, association_path, record_path
      )
      association.changed.each do |change|
        walk_record_change(change, association.kind, association_path, record_path)
      end
    end

    #: (Array[RecordSnapshot], Symbol, traversal_state, CollectionAssociationDiff, traversal_association_path, traversal_record_path) -> void
    def walk_memberships( # rubocop:disable Metrics/ParameterLists
      snapshots, kind, state, association, association_path, record_path
    )
      snapshots.each do |snapshot|
        walk_membership(snapshot, kind, state, association, association_path, record_path)
      end
    end

    #: (RecordSnapshot, Symbol, traversal_state, CollectionAssociationDiff, traversal_association_path, traversal_record_path) -> void
    def walk_membership( # rubocop:disable Metrics/ParameterLists
      snapshot, kind, state, association, association_path, record_path
    )
      child_records = record_path + [snapshot.reference]
      emit_membership(snapshot, kind, state, association, association_path, child_records)
      @snapshots.call(
        snapshot,
        association_path: association_path,
        record_path: child_records,
        state: state,
        association_kind: association.kind,
        include_record: false
      )
    end

    #: (RecordSnapshot, Symbol, traversal_state, CollectionAssociationDiff, traversal_association_path, traversal_record_path) -> void
    def emit_membership( # rubocop:disable Metrics/ParameterLists
      snapshot, kind, state, association, association_path, record_path
    )
      emit(
        kind: kind,
        context: :change,
        association_path: association_path,
        record_path: record_path,
        association_kind: association.kind,
        state: state,
        value: snapshot
      )
    end

    #: (ToOneAssociationDiff, traversal_association_path, traversal_record_path) -> void
    def walk_to_one(association, association_path, record_path)
      if association.relationship
        walk_relationship(association.relationship, association.kind, association_path, record_path)
      elsif association.changed
        walk_record_change(association.changed, association.kind, association_path, record_path)
      end
    end

    #: (ValueChange, Symbol, traversal_association_path, traversal_record_path) -> void
    def walk_relationship(change, association_kind, association_path, record_path)
      emit_relationship(change, association_kind, association_path, record_path)
      walk_related(change.from, :before, association_kind, association_path, record_path)
      walk_related(change.to, :after, association_kind, association_path, record_path)
    end

    #: (ValueChange, Symbol, traversal_association_path, traversal_record_path) -> void
    def emit_relationship(change, association_kind, association_path, record_path)
      emit(
        kind: relationship_kind(change),
        context: :change,
        association_path: association_path,
        record_path: record_path,
        association_kind: association_kind,
        value: change
      )
    end

    #: (RecordSnapshot?, traversal_state, Symbol, traversal_association_path, traversal_record_path) -> void
    def walk_related(snapshot, state, association_kind, association_path, record_path)
      return unless snapshot

      @snapshots.call(
        snapshot,
        association_path: association_path,
        record_path: record_path + [snapshot.reference],
        state: state,
        association_kind: association_kind
      )
    end

    #: (ValueChange) -> Symbol
    def relationship_kind(change)
      return :relationship_added unless change.from
      return :relationship_removed unless change.to

      :relationship_replaced
    end

    #: (RecordChange, Symbol, traversal_association_path, traversal_record_path) -> void
    def walk_record_change(change, association_kind, association_path, record_path)
      child_records = record_path + [change.record]
      emit_record_change(change, association_kind, association_path, child_records)
      attributes(
        change.attributes,
        association_path: association_path,
        record_path: child_records,
        association_kind: association_kind
      )
      call(change.associations, association_path: association_path, record_path: child_records)
    end

    #: (RecordChange, Symbol, traversal_association_path, traversal_record_path) -> void
    def emit_record_change(change, association_kind, association_path, record_path)
      emit(
        kind: :record_changed,
        context: :change,
        association_path: association_path,
        record_path: record_path,
        association_kind: association_kind,
        value: change
      )
    end
  end
  private_constant :AssociationDiffTraversal
end
