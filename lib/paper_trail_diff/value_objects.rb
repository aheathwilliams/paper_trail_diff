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
