# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # A directional change between two structured values.
  class ValueChange
    attr_reader :from #: untyped
    attr_reader :to #: untyped

    #: (from: untyped, to: untyped) -> void
    def initialize(from:, to:)
      @from = Support.immutable_copy(from)
      @to = Support.immutable_copy(to)
      freeze
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      { from: Support.serialize(from), to: Support.serialize(to) }
    end
  end

  # A change to an array inside a value the database stores whole, reported by
  # membership rather than by position.
  #
  # Position would be the obvious thing to report and the wrong one: elements
  # here carry no identity, so inserting at the front makes every later index
  # look changed, and one insertion is described as several edits. Membership is
  # answerable without claiming any pairing -- "gained \"saturn v\"" is true
  # whether the array is a set, a queue, or a ranked list.
  #
  # That leaves one case membership cannot see, so it is named rather than
  # hidden: the same elements in a different order. `reordered?` says so.
  #
  # An element that is itself a Hash or Array is reported whole. Saying which
  # field of which object changed would require pairing before-elements with
  # after-elements, and nothing in the value licenses that pairing.
  class ArrayChange
    attr_reader :from #: Array[untyped]
    attr_reader :to #: Array[untyped]
    attr_reader :added #: Array[untyped]
    attr_reader :removed #: Array[untyped]

    #: (from: Array[untyped], to: Array[untyped]) -> void
    def initialize(from:, to:)
      @from = Support.immutable_copy(from)
      @to = Support.immutable_copy(to)
      @added = Support.immutable_copy(ArrayChange.surplus(to, from))
      @removed = Support.immutable_copy(ArrayChange.surplus(from, to))
      freeze
    end

    # Elements of `left` with no counterpart left in `right`, matching by value
    # and respecting duplicates, so ["a", "a"] -> ["a"] reports one removal
    # rather than none.
    #: (Array[untyped], Array[untyped]) -> Array[untyped]
    def self.surplus(left, right)
      pool = right.dup
      left.reject do |item|
        index = pool.index(item)
        index ? pool.delete_at(index) || true : false
      end
    end

    # Same elements, different sequence. Only meaningful for a change that was
    # recorded at all, which this only is when the two sides differ.
    #: () -> bool
    def reordered?
      added.empty? && removed.empty?
    end

    #: () -> bool
    def empty?
      from == to
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        from: Support.serialize(from),
        to: Support.serialize(to),
        added: Support.serialize(added),
        removed: Support.serialize(removed),
        reordered: reordered?
      }
    end
  end

  # Attribute and nested-association changes for a record whose identity did not change.
  class RecordChange
    attr_reader :record #: RecordReference
    attr_reader :attributes #: Hash[String, ValueChange]
    attr_reader :associations #: Hash[String, ToOneAssociationDiff | CollectionAssociationDiff]

    #: (record: RecordSnapshot, attributes: attribute_changes, ?associations: association_diffs) -> void
    def initialize(record:, attributes:, associations: {})
      @record = record.reference
      @attributes = Support.immutable_copy(attributes)
      @associations = Support.immutable_copy(associations)
      freeze
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      value = { record: Support.serialize(record), attributes: Support.serialize(attributes) }
      value[:associations] = Support.serialize(associations) unless associations.empty?
      value
    end
  end

  # Relationship and associated-record changes for belongs_to or has_one.
  class ToOneAssociationDiff
    attr_reader :kind #: Symbol
    attr_reader :relationship #: ValueChange?
    attr_reader :changed #: RecordChange?

    #: (kind: Symbol, relationship: ValueChange?, changed: RecordChange?) -> void
    def initialize(kind:, relationship:, changed:)
      @kind = kind
      @relationship = relationship
      @changed = changed
      freeze
    end

    #: () -> bool
    def empty?
      relationship.nil? && changed.nil?
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        kind: kind,
        relationship: Support.serialize(relationship),
        changed: Support.serialize(changed)
      }
    end
  end

  # Membership and associated-record changes for has_many.
  class CollectionAssociationDiff
    attr_reader :kind #: Symbol
    attr_reader :added #: Array[RecordSnapshot]
    attr_reader :removed #: Array[RecordSnapshot]
    attr_reader :changed #: Array[RecordChange]

    #: (kind: Symbol, added: Array[RecordSnapshot], removed: Array[RecordSnapshot], changed: Array[RecordChange]) -> void
    def initialize(kind:, added:, removed:, changed:)
      @kind = kind
      @added = added.dup.freeze
      @removed = removed.dup.freeze
      @changed = changed.dup.freeze
      freeze
    end

    #: () -> bool
    def empty?
      added.empty? && removed.empty? && changed.empty?
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        kind: kind,
        added: Support.serialize(added),
        removed: Support.serialize(removed),
        changed: Support.serialize(changed)
      }
    end
  end

  # The complete structured difference between two normalized endpoints.
  class Diff
    attr_reader :record_presence_change #: ValueChange?
    attr_reader :attributes #: Hash[String, ValueChange]
    attr_reader :associations #: Hash[String, ToOneAssociationDiff | CollectionAssociationDiff]

    #: (?record_presence_change: ValueChange?, ?attributes: attribute_changes, ?associations: association_diffs) -> void
    def initialize(record_presence_change: nil, attributes: {}, associations: {})
      @record_presence_change = record_presence_change
      @attributes = Support.immutable_copy(attributes)
      @associations = Support.immutable_copy(associations)
      freeze
    end

    #: () -> bool
    def empty?
      record_presence_change.nil? && attributes.empty? && associations.empty?
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        record_presence_change: Support.serialize(record_presence_change),
        attributes: Support.serialize(attributes),
        associations: Support.serialize(associations)
      }
    end
  end
end
