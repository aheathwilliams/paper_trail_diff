# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Validates and reuses caller-owned live records without issuing association queries.
  class PreloadedEndpointBatchLoader
    #: (tree: AssociationTree, traversal: AssociationTraversal) -> void
    def initialize(tree:, traversal:)
      @tree = tree
      @traversal = traversal
    end

    #: (Array[untyped]) -> Hash[identity, untyped]
    def call(records)
      records.each { |record| validate_record(record, @tree, path: '') }
      records.to_h { |record| [Endpoint.identity(record), record] }
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal

    #: (untyped, AssociationTree, path: String) -> void
    def validate_record(record, tree, path:)
      @traversal.reflections_for(record.class, tree, path: path).each do |reflection|
        validate_association(record, tree, path, reflection)
      end
    end

    #: (untyped, AssociationTree, String, untyped) -> void
    def validate_association(record, tree, path, reflection)
      association_path = Support.association_path(path, reflection.name.to_s)
      association = record.association(reflection.name)
      unless association.loaded?
        message = "current endpoint association is not preloaded: #{association_path}"
        raise UnloadedAssociationError, message
      end

      subtree = tree.child(reflection.name)
      return unless subtree

      Array(association.target).compact.each do |child|
        validate_record(child, subtree, path: association_path)
      end
    end
  end
end
