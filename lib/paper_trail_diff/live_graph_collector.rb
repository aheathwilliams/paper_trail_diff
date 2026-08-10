# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Flattens an already-preloaded, explicitly bounded live association graph.
  class LiveGraphCollector
    #: (tree: AssociationTree, traversal: AssociationTraversal) -> void
    def initialize(tree:, traversal:)
      @tree = tree
      @traversal = traversal
    end

    #: (Array[untyped]) -> Array[untyped]
    def call(records)
      collected = {} #: Hash[Array[untyped], untyped]
      collect(records, @tree, path: '', into: collected)
      collected.values
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal

    #: (Array[untyped], AssociationTree, path: String, into: Hash[Array[untyped], untyped]) -> void
    def collect(records, tree, path:, into:)
      records.each { |record| into[Endpoint.identity(record)] = record }
      records.group_by(&:class).each do |model_class, grouped|
        collect_group(model_class, grouped, tree, path: path, into: into)
      end
    end

    #: (untyped, Array[untyped], AssociationTree, path: String, into: Hash[Array[untyped], untyped]) -> void
    def collect_group(model_class, records, tree, path:, into:)
      @traversal.reflections_for(model_class, tree, path: path).each do |reflection|
        subtree = tree.child(reflection.name)
        next unless subtree

        child_path = Support.association_path(path, reflection.name.to_s)
        collect(children_for(records, reflection), subtree, path: child_path, into: into)
      end
    end

    #: (Array[untyped], untyped) -> Array[untyped]
    def children_for(records, reflection)
      records.flat_map do |record|
        associated = record.public_send(reflection.name)
        reflection.collection? ? associated.to_a : Array(associated).compact
      end
    end
  end
end
