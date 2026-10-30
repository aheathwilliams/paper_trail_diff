# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Compares collection snapshots with a low-allocation path for stable membership.
  # Snapshots hold their records in type and ID order, so results follow it
  # without sorting here.
  class CollectionComparator
    #: (AssociationSnapshot, AssociationSnapshot, record_comparer: untyped) -> void
    def initialize(from_association, to_association, record_comparer:)
      @from = from_association
      @to = to_association
      @record_comparer = record_comparer
    end

    #: () -> CollectionAssociationDiff
    def call
      transition = @to.transition_from(@from)
      return transition_difference(transition) if transition

      aligned = aligned_changes
      return difference(added: [], removed: [], changed: aligned) if aligned

      indexed_difference
    end

    private

    # @rbs @from: AssociationSnapshot
    # @rbs @to: AssociationSnapshot
    # @rbs @record_comparer: untyped

    # A transition names the one record that changed between adjacent
    # snapshots. With matching identities it is an update; otherwise the
    # before record left and the after record joined.
    #: (CollectionTransition) -> CollectionAssociationDiff
    def transition_difference(transition)
      @from.validate_unique_identities!
      @to.validate_unique_identities!
      before = transition.before
      after = transition.after
      if before && after && before.identity == after.identity
        change = @record_comparer.call(before, after)
        return difference(added: [], removed: [], changed: change ? [change] : [])
      end

      difference(added: [after].compact, removed: [before].compact, changed: [])
    end

    #: () -> Array[RecordChange]?
    def aligned_changes
      pairs = aligned_changed_pairs
      return unless pairs

      pairs.filter_map { |pair| @record_comparer.call(pair.fetch(0), pair.fetch(1)) }
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
      seen = Set.new #: Set[identity]
      changed = [] #: Array[[RecordSnapshot, RecordSnapshot]]
      index = 0
      while index < from_records.length
        from_record = from_records.fetch(index)
        to_record = to_records.fetch(index)
        identity = from_record.identity
        raise_duplicate_identity!(identity) unless seen.add?(identity)
        return unless identity == to_record.identity

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
      (records.keys - other_records.keys).map { |identity| records.fetch(identity) }
    end

    #: (Hash[identity, RecordSnapshot], Hash[identity, RecordSnapshot]) -> Array[RecordChange]
    def changed_records(from_records, to_records)
      (from_records.keys & to_records.keys).filter_map do |identity|
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

    #: (identity) -> void
    def raise_duplicate_identity!(identity)
      raise ArgumentError, "duplicate record identity: #{identity}"
    end
  end
end
