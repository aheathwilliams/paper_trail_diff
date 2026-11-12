# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The records one snapshot of a root holds under each of its associations,
  # at any depth, kept up as a replay moves from each snapshot to the next.
  #
  # Looking through a snapshot for a record means reading every collection in
  # it, and a replay asks for each of its events, so its time grew with its
  # events times the records of the tree. A snapshot differs from the one
  # before it by the record its event changed, which the collections say
  # (see AssociationSnapshot#transition_to), so moving costs what changed.
  #
  # A record can be in a tree at several places, so each is counted.
  class SnapshotMembers
    #: () -> void
    def initialize
      @snapshot = nil
      @counts = {} #: Hash[String, Hash[String, Hash[String, Integer]]]
    end

    #: (RecordSnapshot?) -> void
    def move_to(snapshot)
      before = @snapshot&.associations || {}
      after = snapshot&.associations || {}
      (before.keys | after.keys).each do |name|
        change(@counts[name] ||= {}, before[name], after[name])
      end
      @snapshot = snapshot
    end

    # Whether a record of one of the types is under one of the root's
    # associations named. Ids match by their text, as a collection's do.
    #: (Array[String], Array[String?], untyped) -> bool
    def holds?(branches, types, id)
      text = id.to_s
      branches.any? do |name|
        counts = @counts[name]
        !counts.nil? && types.any? { |type| counts[type.to_s]&.key?(text) }
      end
    end

    private

    # @rbs @snapshot: RecordSnapshot?
    # @rbs @counts: Hash[String, Hash[String, Hash[String, Integer]]]

    #: (Hash[String, Hash[String, Integer]], AssociationSnapshot?, AssociationSnapshot?) -> void
    def change(counts, before, after)
      return if before.equal?(after)

      transition = (after.transition_from(before) if before && after)
      return replace(counts, transition.before, transition.after) if transition

      compare(counts, before ? before.records : [], after ? after.records : [])
    end

    # Two collections with no transition between them share the records
    # before and after those that changed.
    #: (Hash[String, Hash[String, Integer]], Array[RecordSnapshot], Array[RecordSnapshot]) -> void
    def compare(counts, before, after)
      head = shared(before, after)
      tail = shared(before.drop(head).reverse, after.drop(head).reverse)
      exchange(counts, before[head, before.length - head - tail] || [],
               after[head, after.length - head - tail] || [])
    end

    # How many records two lists begin with alike.
    #: (Array[RecordSnapshot], Array[RecordSnapshot]) -> Integer
    def shared(left, right)
      limit = [left.length, right.length].min
      (0...limit).find { |index| !left.fetch(index).equal?(right.fetch(index)) } || limit
    end

    #: (Hash[String, Hash[String, Integer]], Array[RecordSnapshot], Array[RecordSnapshot]) -> void
    def exchange(counts, before, after)
      return replace(counts, before.first, after.first) if before.length == 1 && after.length == 1

      before.each { |record| count(counts, record, -1) }
      after.each { |record| count(counts, record, 1) }
    end

    # A record that stays is followed into its collections; another is taken
    # out, or put in, with everything it holds.
    #: (Hash[String, Hash[String, Integer]], RecordSnapshot?, RecordSnapshot?) -> void
    def replace(counts, before, after)
      if before && after && before.identity.eql?(after.identity)
        follow(counts, before, after)
      else
        count(counts, before, -1)
        count(counts, after, 1)
      end
    end

    #: (Hash[String, Hash[String, Integer]], RecordSnapshot, RecordSnapshot) -> void
    def follow(counts, before, after)
      (before.associations.keys | after.associations.keys).each do |name|
        change(counts, before.associations[name], after.associations[name])
      end
    end

    #: (Hash[String, Hash[String, Integer]], RecordSnapshot?, Integer) -> void
    def count(counts, record, by)
      return unless record

      ids = counts[record.type] ||= {}
      text = record.id.to_s
      held = ids.fetch(text, 0) + by
      held.zero? ? ids.delete(text) : ids[text] = held
      record.associations.each_value do |association|
        association.records.each { |nested| count(counts, nested, by) }
      end
    end
  end
end
