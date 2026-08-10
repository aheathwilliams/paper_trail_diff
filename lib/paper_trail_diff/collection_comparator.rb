# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Compares collection snapshots with a low-allocation path for stable membership.
  class CollectionComparator
    #: (AssociationSnapshot, AssociationSnapshot, record_comparer: untyped) -> void
    def initialize(from_association, to_association, record_comparer:)
      @from = from_association
      @to = to_association
      @record_comparer = record_comparer
    end

    #: () -> CollectionAssociationDiff
    def call
      aligned = aligned_changes
      return difference(added: [], removed: [], changed: aligned) if aligned

      indexed_difference
    end

    private

    # @rbs @from: AssociationSnapshot
    # @rbs @to: AssociationSnapshot
    # @rbs @record_comparer: untyped

    #: () -> Array[RecordChange]?
    def aligned_changes
      pairs = aligned_changed_pairs
      return unless pairs

      pairs.sort_by { |_from, to| sortable_identity(to.identity) }.filter_map do |pair|
        @record_comparer.call(pair.fetch(0), pair.fetch(1))
      end
    end

    #: () -> Array[[RecordSnapshot, RecordSnapshot]]?
    def aligned_changed_pairs
      from_records = @from.records
      to_records = @to.records
      return unless from_records.length == to_records.length

      collect_aligned_pairs(from_records, to_records)
    end

    #: (Array[RecordSnapshot], Array[RecordSnapshot]) -> Array[[RecordSnapshot, RecordSnapshot]]?
    def collect_aligned_pairs(from_records, to_records)
      seen = {} #: Hash[identity, bool]
      changed = [] #: Array[[RecordSnapshot, RecordSnapshot]]
      index = 0
      while index < from_records.length
        from_record = from_records.fetch(index)
        to_record = to_records.fetch(index)
        identity = from_record.identity
        raise_duplicate_identity!(identity) if seen.key?(identity)
        return unless identity == to_record.identity

        seen[identity] = true
        changed << [from_record, to_record] unless from_record.equal?(to_record)
        index += 1
      end
      changed
    end

    #: () -> CollectionAssociationDiff
    def indexed_difference
      from_records = index_records(@from.records)
      to_records = index_records(@to.records)
      difference(
        added: records_missing_from(to_records, from_records),
        removed: records_missing_from(from_records, to_records),
        changed: changed_records(from_records, to_records)
      )
    end

    #: (added: Array[RecordSnapshot], removed: Array[RecordSnapshot], changed: Array[RecordChange]) -> CollectionAssociationDiff
    def difference(added:, removed:, changed:)
      CollectionAssociationDiff.new(
        kind: @from.kind,
        added: added,
        removed: removed,
        changed: changed
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
        from_record = from_records.fetch(identity)
        to_record = to_records.fetch(identity)
        next if from_record.equal?(to_record)

        @record_comparer.call(from_record, to_record)
      end
    end

    #: (Array[RecordSnapshot]) -> Hash[identity, RecordSnapshot]
    def index_records(records)
      index = {} #: Hash[identity, RecordSnapshot]
      records.each do |record|
        identity = record.identity
        raise_duplicate_identity!(identity) if index.key?(identity)

        index[identity] = record
      end
      index
    end

    #: (Array[identity]) -> Array[identity]
    def sorted_identities(identities)
      identities.sort_by { |identity| sortable_identity(identity) }
    end

    #: (identity) -> Array[untyped]
    def sortable_identity(identity)
      [identity.fetch(0), identity.fetch(1).inspect]
    end

    #: (identity) -> void
    def raise_duplicate_identity!(identity)
      raise ArgumentError, "duplicate record identity: #{identity.inspect}"
    end
  end
end
