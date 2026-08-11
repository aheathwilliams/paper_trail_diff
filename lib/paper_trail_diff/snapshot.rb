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

    # Non-semantic memoization shared by structurally adjacent snapshots. The
    # cached value is derived only from frozen records and is itself immutable.
    class IdentityIndexCache
      #: () -> void
      def initialize
        @index = nil #: CollectionIdentityIndex?
      end

      #: (Array[RecordSnapshot]) -> CollectionIdentityIndex
      def index(records)
        @index ||= CollectionIdentityIndex.new(records)
      end
    end
    private_constant :IdentityIndexCache

    # Identifies one snapshot for internal carry-forward. A transition cannot
    # hold its origin without retaining every earlier snapshot at that path,
    # and `object_id` is only guaranteed unique among live objects, so Ruby may
    # hand a collected snapshot's id to a later one.
    class SerialSequence
      #: () -> void
      def initialize
        @mutex = Mutex.new
        @counter = 0
      end

      #: () -> Integer
      def next_serial
        @mutex.synchronize { @counter += 1 }
      end

      # @rbs @mutex: Thread::Mutex
      # @rbs @counter: Integer
    end
    private_constant :SerialSequence

    SERIALS = SerialSequence.new
    private_constant :SERIALS

    class << self
      #: (Symbol) -> bool
      def collection_kind?(kind)
        COLLECTION_KINDS.include?(kind)
      end
    end

    attr_reader :kind #: Symbol
    attr_reader :records #: Array[RecordSnapshot]
    attr_reader :serial #: Integer

    #: (kind: Symbol, records: Array[RecordSnapshot], ?identity_index_cache: untyped, ?transition: CollectionTransition?) -> void
    def initialize(kind:, records:, identity_index_cache: nil, transition: nil)
      unless SUPPORTED_KINDS.include?(kind)
        raise ArgumentError, "unsupported association kind: #{kind.inspect}"
      end
      if !self.class.collection_kind?(kind) && records.length > 1
        raise ArgumentError, "#{kind} association snapshots accept at most one record"
      end

      @kind = kind
      @records = records.frozen? ? records : records.dup.freeze
      @identity_index_cache = identity_index_cache || IdentityIndexCache.new
      @transition = transition
      @serial = SERIALS.next_serial
      freeze
    end

    # Builds a structurally adjacent collection snapshot for internal activity carry-forward.
    #: (Array[RecordSnapshot], before: RecordSnapshot?, after: RecordSnapshot?, membership_preserved: bool) -> AssociationSnapshot
    def transition_to(records, before:, after:, membership_preserved:)
      cache = membership_preserved ? @identity_index_cache : nil
      transition = if before || after
                     CollectionTransition.new(from: self, before: before, after: after)
                   end
      self.class.new(
        kind: kind,
        records: records,
        identity_index_cache: cache,
        transition: transition
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

    # @rbs @identity_index_cache: untyped
    # @rbs @transition: CollectionTransition?

    #: () -> CollectionIdentityIndex
    def identity_index
      @identity_index_cache.index(records)
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
