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
    COLLECTION_KINDS = %i[has_many].freeze
    private_constant :COLLECTION_KINDS

    # Whether a collection's identities were found distinct. The snapshots a
    # transition derives from one another share the answer: a transition
    # replaces a record in its place, takes one out, or puts in one that was
    # not there, and none of those can repeat an identity. Records are held
    # in identity order, so two with one identity are neighbours.
    class IdentityCheck
      #: () -> void
      def initialize
        @passed = false
      end

      #: (Array[RecordSnapshot]) -> void
      def call(records)
        return if @passed

        records.map(&:identity).each_cons(2) do |left, right|
          raise ArgumentError, "duplicate record identity: #{right}" if left.eql?(right)
        end
        @passed = true
      end
    end
    private_constant :IdentityCheck

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

    # `ordered` says the records are already in documented order, as a
    # transition's are: checking them again for each event made a replay's
    # time grow with its events times the size of the collection they changed.
    #: (kind: Symbol, records: Array[RecordSnapshot], ?identity_check: untyped, ?transition: CollectionTransition?, ?ordered: bool) -> void
    def initialize(kind:, records:, identity_check: nil, transition: nil, ordered: false)
      unless SUPPORTED_ASSOCIATION_MACROS.include?(kind)
        raise ArgumentError, "unsupported association kind: #{kind.inspect}"
      end
      if !self.class.collection_kind?(kind) && records.length > 1
        raise ArgumentError, "#{kind} association snapshots accept at most one record"
      end

      @kind = kind
      @records = ordered ? in_order(records) : ordered(records)
      @identity_check = identity_check || IdentityCheck.new
      @identity_index = CollectionIdentityIndex.new(@records)
      @transition = transition
      @serial = SERIALS.next_serial
      freeze
    end

    # Builds a structurally adjacent collection snapshot for internal activity
    # carry-forward. Its records are this one's with one of them replaced in
    # its place, taken out, or put in where its identity sorts, so they are in
    # order, and as distinct as these unless the record put in repeats one
    # beside it.
    #: (Array[RecordSnapshot], before: RecordSnapshot?, after: RecordSnapshot?) -> AssociationSnapshot
    def transition_to(records, before:, after:)
      transition = if before || after
                     CollectionTransition.new(from: self, before: before, after: after)
                   end
      self.class.new(
        kind: kind,
        records: records,
        identity_check: (@identity_check unless after && repeated?(records, after)),
        transition: transition,
        ordered: true
      )
    end

    # Collections are documented in record type, then ID, order wherever they
    # were read from. Most arrive sorted, so they are checked before sorting.
    #: (Array[RecordSnapshot]) -> Array[RecordSnapshot]
    def ordered(records)
      keys = records.map { |record| Support.sortable_identity(record.type, record.id) }
      return records.sort_by.with_index { |_, index| keys.fetch(index) }.freeze unless sorted?(keys)

      in_order(records)
    end

    #: (Array[Array[untyped]]) -> bool
    def sorted?(keys)
      keys.each_cons(2).all? { |left, right| (left <=> right).to_i <= 0 }
    end

    #: (AssociationSnapshot) -> CollectionTransition?
    def transition_from(association)
      @transition if @transition&.from?(association)
    end

    #: (untyped, untyped) -> Integer?
    def position(type, id)
      @identity_index.position(type, id)
    end

    #: (untyped) -> Integer?
    def position_for_id(id)
      @identity_index.position_for_id(id)
    end

    #: () -> void
    def validate_unique_identities!
      @identity_check.call(records)
      nil
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      { kind: kind, records: Support.serialize(records) }
    end

    private

    # @rbs @identity_check: untyped
    # @rbs @identity_index: CollectionIdentityIndex
    # @rbs @transition: CollectionTransition?

    #: (Array[RecordSnapshot]) -> Array[RecordSnapshot]
    def in_order(records)
      records.frozen? ? records : records.dup.freeze
    end

    # Whether the records hold this record's identity twice: a second one
    # follows the first in their order.
    #: (Array[RecordSnapshot], RecordSnapshot) -> bool
    def repeated?(records, record)
      first = CollectionIdentityIndex.new(records).insertion(record.type, record.id)
      twin = records[first + 1]
      !twin.nil? && twin.identity.eql?(record.identity)
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
      unless type.is_a?(String)
        raise ArgumentError, "record type must be a String, not #{type.inspect}"
      end

      @type = Support.immutable_copy(type)
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

    # A copy holding a different state for one association.
    #: (String, AssociationSnapshot) -> RecordSnapshot
    def with_association(name, association)
      self.class.new(
        type: type, id: id, attributes: attributes,
        associations: associations.merge(name => association)
      )
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
