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

    #: (AssociationSnapshot, untyped, RecordSnapshot?) -> [Array[RecordSnapshot], RecordSnapshot?, RecordSnapshot?, bool]
    def call(association, version, replacement)
      records = association.records
      position = association.position(replacement_type(version, replacement), version.item_id)
      return [records, nil, nil, true] unless replacement || position

      before = records.fetch(position) if position
      updated = replacement_records(records, position, replacement)
      [updated, before, replacement, !before.nil? && !replacement.nil?]
    end

    #: (untyped, RecordSnapshot?) -> String
    def replacement_type(version, replacement)
      return replacement.type.to_s if replacement

      Endpoint.model_class(version).name.to_s
    end

    private

    # @rbs @relationship: ActivityRelationship

    #: (Array[RecordSnapshot], Integer?, RecordSnapshot?) -> Array[RecordSnapshot]
    def replacement_records(records, position, replacement)
      updated = records.dup
      if replacement
        position ? updated[position] = replacement : updated << replacement
      else
        position ||= raise(ConfigurationError, 'missing collection event identity')
        updated.delete_at(position)
      end
      updated.freeze
    end
  end
end
