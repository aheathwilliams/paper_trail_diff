# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Immutable positions for one collection membership and ordering.
  class CollectionIdentityIndex
    #: (Array[untyped]) -> void
    def initialize(records)
      @positions = {} #: Hash[Array[untyped], Integer]
      @serialized_positions = {} #: Hash[Array[String], Integer]
      @id_positions = {} #: Hash[String, Integer?]
      records.each_with_index { |record, index| register(record, index) }
      @positions.freeze
      @serialized_positions.freeze
      @id_positions.freeze
      freeze
    end

    #: (untyped, untyped) -> Integer?
    def position(type, id)
      @serialized_positions[[type.to_s, id.to_s]]
    end

    #: (untyped) -> Integer?
    def position_for_id(id)
      @id_positions[id.to_s]
    end

    private

    # @rbs @positions: Hash[Array[untyped], Integer]
    # @rbs @serialized_positions: Hash[Array[String], Integer]
    # @rbs @id_positions: Hash[String, Integer?]

    #: (untyped, Integer) -> void
    def register(record, index)
      identity = record.identity
      if @positions.key?(identity)
        raise ArgumentError, "duplicate record identity: #{identity.inspect}"
      end

      @positions[identity] = index
      @serialized_positions[[record.type.to_s, record.id.to_s]] = index
      register_id(record.id, index)
    end

    #: (untyped, Integer) -> void
    def register_id(id, index)
      key = id.to_s
      @id_positions[key] = @id_positions.key?(key) ? nil : index
    end
  end
end
