# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Replaces a collection event record along one explicit immutable snapshot route.
  class ActivityCollectionRouteUpdater
    #: (pool: SnapshotPool, relationship: ActivityRelationship) -> void
    def initialize(pool:, relationship:)
      @pool = pool
      @relationship = relationship
      @record_updater = ActivityCollectionRecordUpdater.new(relationship)
    end

    #: (RecordSnapshot, ActivityCollectionRouteChange, ?depth: Integer) -> [RecordSnapshot, bool]
    def call(snapshot, change, depth: 0) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      name, _reflection, _subtree, path = change.route.fetch(depth)
      association = snapshot.associations.fetch(name)
      transition = updated_records(association, snapshot, change, depth)
      records, before, after, membership_preserved, changed = transition
      return [snapshot, false] unless changed

      updated_association = @pool.association(
        path,
        association.transition_to(
          records,
          before: before,
          after: after,
          membership_preserved: membership_preserved
        )
      )
      updated_snapshot = replace_association(snapshot, name, updated_association)
      parent_path = depth.zero? ? '' : change.route.fetch(depth - 1).fetch(3)
      updated_snapshot = @pool.record(parent_path, updated_snapshot) unless parent_path.empty?
      [updated_snapshot, true]
    end

    private

    # @rbs @pool: SnapshotPool
    # @rbs @relationship: ActivityRelationship
    # @rbs @record_updater: ActivityCollectionRecordUpdater

    #: (AssociationSnapshot, RecordSnapshot, ActivityCollectionRouteChange, Integer) -> [Array[RecordSnapshot], RecordSnapshot?, RecordSnapshot?, bool, bool]
    def updated_records(association, owner, change, depth)
      return leaf_records(association, owner, change) if depth == change.route.length - 1

      targeted = targeted_parent(association, change, depth)
      if targeted
        records, before, after, changed = targeted
        return [records, before, after, true, changed]
      end

      recursive_records(association, change, depth)
    end

    #: (AssociationSnapshot, RecordSnapshot, ActivityCollectionRouteChange) -> [Array[RecordSnapshot], RecordSnapshot?, RecordSnapshot?, bool, bool]
    def leaf_records(association, owner, change)
      reflection = change.route.last.fetch(1)
      child = @record_updater.event_child(association, change, reflection, owner)
      records, before, after, preserved = @record_updater.call(
        association, change.version, child
      )
      [records, before, after, preserved, !records.equal?(association.records)]
    end

    #: (AssociationSnapshot, ActivityCollectionRouteChange, Integer) -> [Array[RecordSnapshot], RecordSnapshot?, RecordSnapshot?, bool]?
    def targeted_parent(association, change, depth)
      return unless depth == change.route.length - 2

      reflection = change.route.fetch(depth + 1).fetch(1)
      position = nested_owner_position(association, reflection, change)
      return unless position

      before = association.records.fetch(position)
      after, changed = call(before, change, depth: depth + 1)
      targeted_parent_replacement(association.records, position, before, after, changed)
    end

    #: (AssociationSnapshot, ActivityCollectionRouteChange, Integer) -> [Array[RecordSnapshot], RecordSnapshot?, RecordSnapshot?, bool, bool]
    def recursive_records(association, change, depth)
      state = [nil, nil, false] #: [RecordSnapshot?, RecordSnapshot?, bool]
      records = association.records.map do |child|
        updated, child_changed = call(child, change, depth: depth + 1)
        state = recursive_transition(state, child, updated, child_changed)
        updated
      end.freeze
      [records, state.fetch(0), state.fetch(1), true, state.fetch(2)]
    end

    #: ([RecordSnapshot?, RecordSnapshot?, bool], RecordSnapshot, RecordSnapshot, bool) -> [RecordSnapshot?, RecordSnapshot?, bool]
    def recursive_transition(state, child, updated, child_changed)
      return state unless child_changed
      return [nil, nil, true] if state.fetch(2)

      [child, updated, true]
    end

    #: (Array[RecordSnapshot], Integer, RecordSnapshot, RecordSnapshot, bool) -> [Array[RecordSnapshot], RecordSnapshot?, RecordSnapshot?, bool]
    def targeted_parent_replacement(records, position, before, after, changed)
      return [records, nil, nil, false] unless changed

      updated = records.dup
      updated[position] = after
      [updated.freeze, before, after, true]
    end

    #: (AssociationSnapshot, untyped, ActivityCollectionRouteChange) -> Integer?
    def nested_owner_position(association, reflection, change)
      membership_record = change.record || change.version.reify(dup: true)
      return unless membership_record
      return if membership_record.is_a?(ActivitySnapshotDelta) &&
                membership_record.relationship_changed?(reflection)

      owner_id = @relationship.owner_id(membership_record, reflection, state: :after)
      association.position_for_id(owner_id)
    end

    #: (RecordSnapshot, String, AssociationSnapshot) -> RecordSnapshot
    def replace_association(snapshot, name, association)
      RecordSnapshot.new(
        type: snapshot.type,
        id: snapshot.id,
        attributes: snapshot.attributes,
        associations: snapshot.associations.merge(name => association)
      )
    end
  end
end
