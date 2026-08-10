# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Immutable identity shared by snapshots and stable-record changes.
  class RecordReference
    attr_reader :type #: String
    attr_reader :id #: untyped

    #: (type: String, id: untyped) -> void
    def initialize(type:, id:)
      @type = Support.immutable_copy(type.to_s)
      @id = Support.immutable_copy(id)
      freeze
    end

    #: (reference_key) -> untyped
    def [](key)
      case key.to_s
      when 'type' then type
      when 'id' then id
      end
    end

    #: (reference_key) -> untyped
    def fetch(key)
      value = self[key]
      return value if %w[type id].include?(key.to_s)

      raise KeyError, "key not found: #{key.inspect}"
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      { type: type, id: id }
    end
  end

  # A normalized association in a bounded record snapshot tree.
  class AssociationSnapshot
    COLLECTION_KINDS = %i[has_many has_and_belongs_to_many].freeze
    SUPPORTED_KINDS = %i[belongs_to has_one has_many has_and_belongs_to_many].freeze
    private_constant :COLLECTION_KINDS, :SUPPORTED_KINDS

    class << self
      #: (Symbol) -> bool
      def collection_kind?(kind)
        COLLECTION_KINDS.include?(kind)
      end
    end

    attr_reader :kind #: Symbol
    attr_reader :records #: Array[RecordSnapshot]

    #: (kind: Symbol, records: Array[RecordSnapshot], ?identity_index_holder: untyped, ?transition: CollectionTransition?) -> void
    def initialize(kind:, records:, identity_index_holder: nil, transition: nil)
      unless SUPPORTED_KINDS.include?(kind)
        raise ArgumentError, "unsupported association kind: #{kind.inspect}"
      end
      if !self.class.collection_kind?(kind) && records.length > 1
        raise ArgumentError, "#{kind} association snapshots accept at most one record"
      end

      @kind = kind
      @records = records.dup.freeze
      @identity_index_holder = identity_index_holder || [nil]
      @transition = transition
      freeze
    end

    # Builds a structurally adjacent collection snapshot for internal activity carry-forward.
    #: (Array[RecordSnapshot], before: RecordSnapshot?, after: RecordSnapshot?, membership_preserved: bool) -> AssociationSnapshot
    def transition_to(records, before:, after:, membership_preserved:)
      holder = membership_preserved ? @identity_index_holder : nil
      self.class.new(
        kind: kind,
        records: records,
        identity_index_holder: holder,
        transition: CollectionTransition.new(from: self, before: before, after: after)
      )
    end

    #: (AssociationSnapshot) -> CollectionTransition?
    def transition_from(association)
      @transition if @transition&.from?(association)
    end

    #: (untyped, untyped) -> Integer?
    def position(type, id)
      identity_index.position(type, id)
    end

    #: (untyped) -> Integer?
    def position_for_id(id)
      identity_index.position_for_id(id)
    end

    #: () -> void
    def validate_unique_identities!
      identity_index
      nil
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      { kind: kind, records: Support.serialize(records) }
    end

    private

    # @rbs @identity_index_holder: Array[CollectionIdentityIndex?]
    # @rbs @transition: CollectionTransition?

    #: () -> CollectionIdentityIndex
    def identity_index
      @identity_index_holder[0] ||= CollectionIdentityIndex.new(records)
    end
  end

  # An immutable, ActiveRecord-independent representation of a reified record.
  class RecordSnapshot
    attr_reader :type #: String
    attr_reader :id #: untyped
    attr_reader :identity #: Array[untyped]
    attr_reader :attributes #: Hash[String, untyped]
    attr_reader :associations #: Hash[String, AssociationSnapshot]

    #: (type: String, id: untyped, attributes: snapshot_attributes, ?associations: snapshot_associations) -> void
    def initialize(type:, id:, attributes:, associations: {})
      @type = Support.immutable_copy(type.to_s)
      @id = Support.immutable_copy(id)
      @identity = [@type, @id].freeze
      @attributes = normalize_hash(attributes)
      @associations = normalize_hash(associations)
      freeze
    end

    #: () -> RecordReference
    def reference
      RecordReference.new(type: type, id: id)
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      value = {
        type: type,
        id: id,
        attributes: Support.serialize(attributes)
      }
      value[:associations] = Support.serialize(associations) unless associations.empty?
      value
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
