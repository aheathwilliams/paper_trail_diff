# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # A normalized first-level association in a record snapshot.
  class AssociationSnapshot
    SUPPORTED_KINDS = %i[belongs_to has_one has_many].freeze
    private_constant :SUPPORTED_KINDS

    attr_reader :kind #: Symbol
    attr_reader :records #: Array[RecordSnapshot]

    #: (kind: Symbol, records: Array[RecordSnapshot]) -> void
    def initialize(kind:, records:)
      unless SUPPORTED_KINDS.include?(kind)
        raise ArgumentError, "unsupported association kind: #{kind.inspect}"
      end
      if kind != :has_many && records.length > 1
        raise ArgumentError, "#{kind} association snapshots accept at most one record"
      end

      @kind = kind
      @records = records.dup.freeze
      freeze
    end
  end

  # An immutable, ActiveRecord-independent representation of a reified record.
  class RecordSnapshot
    attr_reader :type #: String
    attr_reader :id #: untyped
    attr_reader :attributes #: Hash[String, untyped]
    attr_reader :associations #: Hash[String, AssociationSnapshot]

    #: (type: String, id: untyped, attributes: snapshot_attributes, ?associations: snapshot_associations) -> void
    def initialize(type:, id:, attributes:, associations: {})
      @type = Support.immutable_copy(type.to_s)
      @id = Support.immutable_copy(id)
      @attributes = normalize_hash(attributes)
      @associations = normalize_hash(associations)
      freeze
    end

    #: () -> Array[untyped]
    def identity
      [type, id].freeze
    end

    #: () -> Hash[Symbol, untyped]
    def reference
      { type: type, id: id }
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        type: type,
        id: id,
        attributes: Support.serialize(attributes)
      }
    end

    private

    #: (Hash[untyped, untyped]) -> Hash[String, untyped]
    def normalize_hash(hash)
      normalized = {} #: Hash[String, untyped]
      hash.sort_by { |key, _value| key.to_s }.each do |key, value|
        normalized[Support.immutable_copy(key.to_s)] = Support.immutable_copy(value)
      end
      normalized.freeze
    end
  end
end
