# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Pure snapshot comparison. This class has no ActiveRecord or PaperTrail dependencies.
  class Engine
    class << self
      #: (RecordSnapshot?, RecordSnapshot?) -> Diff
      def compare(from_snapshot, to_snapshot)
        return Diff.new if from_snapshot.nil? && to_snapshot.nil?

        if from_snapshot.nil? || to_snapshot.nil?
          change = ValueChange.new(from: from_snapshot, to: to_snapshot)
          return Diff.new(record_presence_change: change)
        end

        Diff.new(
          attributes: compare_attributes(from_snapshot.attributes, to_snapshot.attributes),
          associations: compare_associations(from_snapshot.associations, to_snapshot.associations)
        )
      end

      private

      #: (Hash[String, untyped], Hash[String, untyped]) -> Hash[String, ValueChange]
      def compare_attributes(from_attributes, to_attributes)
        changes = {} #: attribute_changes
        (from_attributes.keys | to_attributes.keys).sort.each do |name|
          from_value = from_attributes[name]
          to_value = to_attributes[name]
          next if from_value == to_value

          changes[name] = ValueChange.new(from: from_value, to: to_value)
        end
        changes
      end

      #: (association_snapshots, association_snapshots) -> association_diffs
      def compare_associations(from_associations, to_associations)
        changes = {} #: association_diffs
        (from_associations.keys | to_associations.keys).sort.each do |name|
          from_association, to_association = association_pair(
            from_associations[name],
            to_associations[name]
          )
          difference = compare_association(from_association, to_association)
          changes[name] = difference unless difference.empty?
        end
        changes
      end

      #: (AssociationSnapshot?, AssociationSnapshot?) -> [AssociationSnapshot, AssociationSnapshot]
      def association_pair(from_association, to_association)
        validate_association_kinds!(from_association, to_association)
        association = from_association || to_association
        raise ArgumentError, 'association pair cannot be empty' unless association

        kind = association.kind

        [
          from_association || AssociationSnapshot.new(kind: kind, records: []),
          to_association || AssociationSnapshot.new(kind: kind, records: [])
        ]
      end

      #: (AssociationSnapshot?, AssociationSnapshot?) -> void
      def validate_association_kinds!(from_association, to_association)
        return unless kinds_differ?(from_association, to_association)

        raise ArgumentError, 'association kind changed between snapshots'
      end

      #: (AssociationSnapshot?, AssociationSnapshot?) -> bool
      def kinds_differ?(from_association, to_association)
        return false unless from_association && to_association

        from_association.kind != to_association.kind
      end

      #: (AssociationSnapshot, AssociationSnapshot) -> association_diff
      def compare_association(from_association, to_association)
        if from_association.kind == :has_many
          return compare_collection(from_association, to_association)
        end

        compare_to_one(from_association, to_association)
      end

      #: (AssociationSnapshot, AssociationSnapshot) -> ToOneAssociationDiff
      def compare_to_one(from_association, to_association)
        from_record = from_association.records.first
        to_record = to_association.records.first
        if same_identity?(from_record, to_record)
          return ToOneAssociationDiff.new(
            kind: from_association.kind,
            relationship: nil,
            changed: compare_record(from_record, to_record)
          )
        end

        ToOneAssociationDiff.new(
          kind: from_association.kind,
          relationship: relationship_change(from_record, to_record),
          changed: nil
        )
      end

      #: (RecordSnapshot?, RecordSnapshot?) -> ValueChange?
      def relationship_change(from_record, to_record)
        return unless from_record || to_record

        ValueChange.new(from: from_record, to: to_record)
      end

      #: (RecordSnapshot, RecordSnapshot) -> RecordChange?
      def compare_record(from_record, to_record)
        attributes = compare_attributes(from_record.attributes, to_record.attributes)
        RecordChange.new(record: to_record, attributes: attributes) unless attributes.empty?
      end

      #: (AssociationSnapshot, AssociationSnapshot) -> CollectionAssociationDiff
      def compare_collection(from_association, to_association)
        from_records = index_records(from_association.records)
        to_records = index_records(to_association.records)

        CollectionAssociationDiff.new(
          kind: :has_many,
          added: records_missing_from(to_records, from_records),
          removed: records_missing_from(from_records, to_records),
          changed: changed_records(from_records, to_records)
        )
      end

      #: (Hash[identity, RecordSnapshot], Hash[identity, RecordSnapshot]) -> Array[RecordSnapshot]
      def records_missing_from(records, other_records)
        identities = sorted_identities(records.keys - other_records.keys)
        identities.map { |identity| records.fetch(identity) }
      end

      #: (Hash[identity, RecordSnapshot], Hash[identity, RecordSnapshot]) -> Array[RecordChange]
      def changed_records(from_records, to_records)
        sorted_identities(from_records.keys & to_records.keys).filter_map do |identity|
          compare_record(from_records.fetch(identity), to_records.fetch(identity))
        end
      end

      #: (Array[RecordSnapshot]) -> Hash[Array[untyped], RecordSnapshot]
      def index_records(records)
        index = {} #: Hash[identity, RecordSnapshot]
        records.each do |record|
          if index.key?(record.identity)
            raise ArgumentError, "duplicate record identity: #{record.identity.inspect}"
          end

          index[record.identity] = record
        end
        index
      end

      #: (Array[Array[untyped]]) -> Array[Array[untyped]]
      def sorted_identities(identities)
        identities.sort_by { |type, id| [type, id.inspect] }
      end

      #: (RecordSnapshot?, RecordSnapshot?) -> bool
      def same_identity?(from_record, to_record)
        from_record && to_record ? from_record.identity == to_record.identity : false
      end
    end
  end
end
