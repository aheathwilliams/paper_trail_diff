# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reloads current-record endpoints and their explicitly selected associations in batches.
  class LiveEndpointBatchLoader
    #: (tree: AssociationTree) -> void
    def initialize(tree:)
      @tree = tree
    end

    #: (Array[untyped]) -> Hash[identity, untyped]
    def call(records)
      loaded = {} #: Hash[identity, untyped]
      records.group_by(&:class).each do |model_class, grouped|
        load_group(model_class, grouped).each do |record|
          loaded[Endpoint.identity(record)] = record
        end
      end
      ensure_all_loaded!(records, loaded)
      loaded
    end

    private

    # @rbs @tree: AssociationTree

    #: (untyped, Array[untyped]) -> Array[untyped]
    def load_group(model_class, records)
      relation = model_class.unscoped.where(model_class.primary_key => records.map(&:id).uniq)
      preload = preload_spec(@tree)
      relation = relation.preload(*preload) unless preload.empty?
      relation.to_a
    end

    #: (AssociationTree) -> Array[Symbol | Hash[Symbol, untyped]]
    def preload_spec(tree)
      tree.children.map do |name, subtree|
        key = name.to_sym
        subtree.empty? ? key : { key => preload_spec(subtree) }
      end
    end

    #: (Array[untyped], Hash[identity, untyped]) -> void
    def ensure_all_loaded!(records, loaded)
      missing = records.map { |record| Endpoint.identity(record) }.uniq - loaded.keys
      return if missing.empty?

      message = 'current record endpoint could not be reloaded from the database'
      raise InvalidEndpointError, message
    end
  end
end
