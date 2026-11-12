# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Applies one event to the leaf records of a collection association snapshot.
  class ActivityCollectionRecordUpdater
    #: (ActivityRelationship) -> void
    def initialize(relationship)
      @relationship = relationship
    end

    #: (AssociationSnapshot, ActivityCollectionRouteChange, untyped, RecordSnapshot) -> RecordSnapshot?
    def event_child(association, change, reflection, owner)
      version = change.version
      record = change.record
      replacement = change.replacement
      return unless record

      unless record.is_a?(ActivitySnapshotDelta)
        return replacement if @relationship.member_of_owner?(record, reflection, owner)

        return
      end
      unless record.relationship_changed?(reflection)
        return replacement if association.position_for_id(version.item_id)

        return
      end

      replacement if @relationship.member_of_owner?(record, reflection, owner)
    end

    # The collection's records after the event, with the record it took out
    # and the one it put in.
    #: (AssociationSnapshot, untyped, RecordSnapshot?) -> [Array[RecordSnapshot], RecordSnapshot?, RecordSnapshot?]
    def call(association, version, replacement)
      records = association.records
      position = association.position(replacement_type(version, replacement), version.item_id) ||
                 retyped_position(association, version)
      return [records, nil, nil] unless replacement || position

      before = records.fetch(position) if position
      [replacement_records(records, position, replacement), before, replacement]
    end

    #: (untyped, RecordSnapshot?) -> String
    def replacement_type(version, replacement)
      return replacement.type.to_s if replacement

      Endpoint.model_class(version).name.to_s
    end

    private

    # @rbs @relationship: ActivityRelationship

    # A row whose STI type changed is the same row under a new identity, so it
    # is found by id among the records of its table.
    #: (AssociationSnapshot, untyped) -> Integer?
    def retyped_position(association, version)
      position = association.position_for_id(version.item_id)
      return unless position

      type = association.records.fetch(position).type
      position if Object.const_get(type).base_class == Endpoint.model_class(version).base_class
    rescue NameError
      nil
    end

    # A record that keeps its identity keeps its place. Any other, one that
    # joined or a row whose type changed, goes where its identity sorts, so
    # the records stay in the order a snapshot holds them in without being
    # sorted again for each event.
    #: (Array[RecordSnapshot], Integer?, RecordSnapshot?) -> Array[RecordSnapshot]
    def replacement_records(records, position, replacement)
      updated = records.dup
      if replacement && position && updated.fetch(position).identity == replacement.identity
        updated[position] = replacement
      else
        updated.delete_at(position) if position
        insert(updated, replacement) if replacement
      end
      updated.freeze
    end

    #: (Array[RecordSnapshot], RecordSnapshot) -> void
    def insert(records, record)
      records.insert(CollectionIdentityIndex.new(records).insertion(record.type, record.id), record)
    end
  end
end
