# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Validates and reuses caller-owned live records, reading again only the
  # associations a preload of many records cannot have loaded correctly.
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
      association_path = Support.association_path(path, reflection.name)
      association = record.association(reflection.name)
      unless association.loaded?
        message = "current endpoint association is not preloaded: #{association_path}"
        raise UnloadedAssociationError, message
      end
      read_alone(association) unless BatchPreload.safe?(reflection)

      subtree = tree.child(reflection.name)
      return unless subtree

      Array(association.target).compact.each do |child|
        validate_record(child, subtree, path: association_path)
      end
    end

    # Preloading many records applies a limit or offset to all of them
    # together, so what a caller preloaded cannot be trusted: one record keeps
    # another's share, or none. Such an association is read again for each
    # record, as reloading reads it.
    #: (untyped) -> void
    def read_alone(association)
      association.reset
      association.load_target
    end
  end
end
