# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Immutable positions for one collection membership and ordering.
  class CollectionIdentityIndex
    #: (Array[untyped]) -> void
    def initialize(records)
      @identities = Set.new #: Set[Array[untyped]]
      @serialized_positions = {} #: Hash[Array[String], Integer]
      @id_positions = {} #: Hash[String, Integer?]
      records.each_with_index { |record, index| register(record, index) }
      freeze
    end

    #: (String, untyped) -> Integer?
    def position(type, id)
      @serialized_positions[[type, id.to_s]]
    end

    #: (untyped) -> Integer?
    def position_for_id(id)
      @id_positions[id.to_s]
    end

    private

    # @rbs @identities: Set[Array[untyped]]
    # @rbs @serialized_positions: Hash[Array[String], Integer]
    # @rbs @id_positions: Hash[String, Integer?]

    #: (untyped, Integer) -> void
    def register(record, index)
      identity = record.identity
      unless @identities.add?(identity)
        raise ArgumentError, "duplicate record identity: #{identity}"
      end

      @serialized_positions[[record.type, record.id.to_s]] = index
      register_id(record.id, index)
    end

    #: (untyped, Integer) -> void
    def register_id(id, index)
      key = id.to_s
      @id_positions[key] = (index unless @id_positions.key?(key))
    end
  end
end
