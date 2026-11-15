# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Batched record states and relationship candidates for one activity range.
  class PreparedHistory
    attr_reader :activity_index #: PreparedActivityIndex?

    #: (PreparedRecordIndex, ?activity_index: PreparedActivityIndex?) -> void
    def initialize(records, activity_index: nil)
      @records = records
      @state_reader = PreparedStateAssociationReader.new(records, method(:edge),
                                                         ScopeCondition::Cache.new)
      @activity_index = activity_index
      @edges = {} #: Hash[Array[String], Hash[String, Hash[Symbol, untyped]]]
    end

    # When the history was read from.
    #: () -> untyped
    def start_time = @records.start_time

    #: () -> Array[untyped]
    def versions = @records.versions

    # See PreparedRecordIndex#reading.
    #: (TransactionEnds) { () -> void } -> void
    def reading(ends, &block)
      @records.reading(ends, &block)
    end

    # See PreparedRecordIndex#transaction_ends.
    #: (Array[untyped]) -> TransactionEnds
    def transaction_ends(versions) = @records.transaction_ends(versions)

    #: () -> TransactionEnds?
    def reading_ends = @records.reading_ends

    # Returns every group the edge now holds.
    #: (untyped, untyped, Hash[String, Hash[Symbol, untyped]]) -> Hash[String, Hash[Symbol, untyped]]
    def merge_edge(owner_class, reflection, groups)
      key = edge_key(owner_class, reflection)
      empty = {} #: Hash[String, Hash[Symbol, untyped]]
      @edges[key] = Support.merge_record_groups(@edges.fetch(key, empty), groups)
    end

    #: (untyped, untyped) -> Hash[String, Hash[Symbol, untyped]]
    def edge(owner_class, reflection)
      empty = {} #: Hash[String, Hash[Symbol, untyped]]
      @edges.fetch(edge_key(owner_class, reflection), empty)
    end

    #: (untyped, untyped, untyped) -> [Hash[untyped, untyped], Hash[untyped, untyped]]?
    def record_transition(model_class, id, version)
      @records.transition(model_class, id, version)
    end

    #: (untyped, untyped, untyped) -> [bool, PreparedRecordState?]
    def record_after(model_class, id, version)
      @records.record_after(model_class, id, version)
    end

    # Who was in the owner's association at the boundary (see
    # PreparedStateAssociationReader).
    #: (PreparedRecordState, untyped, untyped) -> Array[PreparedRecordState]
    def snapshot_states(owner, reflection, boundary)
      @state_reader.call(owner, reflection, boundary)
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @state_reader: PreparedStateAssociationReader
    # @rbs @edges: Hash[Array[String], Hash[String, Hash[Symbol, untyped]]]

    #: (untyped, untyped) -> Array[String]
    def edge_key(owner_class, reflection)
      [owner_class.base_class.name.to_s, reflection.name.to_s]
    end
  end
end
