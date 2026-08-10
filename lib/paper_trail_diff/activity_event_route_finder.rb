# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Finds explicitly selected collection and belongs-to routes for one event type.
  class ActivityEventRouteFinder
    #: (AssociationTraversal) -> void
    def initialize(traversal)
      @traversal = traversal
    end

    #: (untyped, AssociationTree, String, ?path: String) -> Array[Array[untyped]]
    def collection_routes(model_class, tree, target_type, path: '')
      routes(model_class, tree, target_type, :has_many, path: path)
    end

    #: (untyped, AssociationTree, String, ?path: String) -> Array[Array[untyped]]
    def belongs_to_routes(model_class, tree, target_type, path: '')
      routes(model_class, tree, target_type, :belongs_to, path: path)
    end

    private

    # @rbs @traversal: AssociationTraversal

    #: (untyped, AssociationTree, String, Symbol, path: String) -> Array[Array[untyped]]
    def routes(model_class, tree, target_type, macro, path: '')
      @traversal.reflections_for(model_class, tree, path: path).flat_map do |reflection|
        routes_for_reflection(reflection, tree, target_type, macro, path)
      end
    end

    #: (untyped, AssociationTree, String, Symbol, String) -> Array[Array[untyped]]
    def routes_for_reflection(reflection, tree, target_type, macro, path)
      name = reflection.name.to_s
      subtree = tree.child(name)
      return [] unless subtree

      child_path = Support.association_path(path, name)
      entry = [name, reflection, subtree, child_path]
      direct = [] #: Array[Array[untyped]]
      direct << [entry] if direct_route?(reflection, target_type, macro)
      return direct if subtree.empty? || reflection.polymorphic?

      nested = routes(reflection.klass, subtree, target_type, macro, path: child_path)
      direct.concat(nested.map { |route| [entry, *route] })
    end

    #: (untyped, String, Symbol) -> bool
    def direct_route?(reflection, target_type, macro)
      reflection.macro == macro && supported_direct_reflection?(reflection, macro) &&
        reflection.klass.base_class.name.to_s == target_type
    end

    #: (untyped, Symbol) -> bool
    def supported_direct_reflection?(reflection, macro)
      return !reflection.options[:through] if macro == :has_many

      !reflection.polymorphic?
    end
  end
end
