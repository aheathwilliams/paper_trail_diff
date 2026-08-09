# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Walks nested state included in an added, removed, or replaced record snapshot.
  class SnapshotTraversal < TraversalEmitter
    #: (RecordSnapshot, association_path: traversal_association_path, record_path: traversal_record_path, state: traversal_state, ?association_kind: Symbol?, ?include_record: bool) -> void
    def call( # rubocop:disable Metrics/ParameterLists
      snapshot,
      association_path:,
      record_path:,
      state:,
      association_kind: nil,
      include_record: true
    )
      if include_record
        emit_record(snapshot, association_path, record_path, state, association_kind)
      end
      emit_attributes(snapshot, association_path, record_path, state, association_kind)
      emit_associations(snapshot, association_path, record_path, state)
    end

    private

    #: (RecordSnapshot, traversal_association_path, traversal_record_path, traversal_state, Symbol?) -> void
    def emit_record(snapshot, association_path, record_path, state, association_kind)
      emit(
        kind: :record_included,
        context: :included_state,
        association_path: association_path,
        record_path: record_path,
        association_kind: association_kind,
        state: state,
        value: snapshot.reference
      )
    end

    #: (RecordSnapshot, traversal_association_path, traversal_record_path, traversal_state, Symbol?) -> void
    def emit_attributes(snapshot, association_path, record_path, state, association_kind)
      snapshot.attributes.each do |name, value|
        emit_attribute(name, value, association_path, record_path, state, association_kind)
      end
    end

    #: (String, untyped, traversal_association_path, traversal_record_path, traversal_state, Symbol?) -> void
    def emit_attribute( # rubocop:disable Metrics/ParameterLists
      name, value, association_path, record_path, state, association_kind
    )
      emit(
        kind: :attribute_included,
        context: :included_state,
        association_path: association_path,
        record_path: record_path,
        association_kind: association_kind,
        state: state,
        attribute: name,
        value: value
      )
    end

    #: (RecordSnapshot, traversal_association_path, traversal_record_path, traversal_state) -> void
    def emit_associations(snapshot, association_path, record_path, state)
      snapshot.associations.each do |name, association|
        child_path = association_path + [name]
        emit_association(association, child_path, record_path, state)
        emit_association_records(association, child_path, record_path, state)
      end
    end

    #: (AssociationSnapshot, traversal_association_path, traversal_record_path, traversal_state) -> void
    def emit_association(association, association_path, record_path, state)
      emit(
        kind: :association_included,
        context: :included_state,
        association_path: association_path,
        record_path: record_path,
        association_kind: association.kind,
        state: state,
        value: association
      )
    end

    #: (AssociationSnapshot, traversal_association_path, traversal_record_path, traversal_state) -> void
    def emit_association_records(association, association_path, record_path, state)
      association.records.each do |snapshot|
        call(
          snapshot,
          association_path: association_path,
          record_path: record_path + [snapshot.reference],
          state: state,
          association_kind: association.kind
        )
      end
    end
  end
  private_constant :SnapshotTraversal
end
