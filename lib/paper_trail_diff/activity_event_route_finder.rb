# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Finds explicitly selected collection and belongs-to routes for one event type.
  class ActivityEventRouteFinder
    #: (AssociationTraversal) -> void
    def initialize(traversal)
      @traversal = traversal
      @collection_model = nil
      @collection_tree = nil #: AssociationTree?
      @collection_type = nil #: String?
      @collection_path = nil #: String?
      @collection_routes = nil #: Array[Array[untyped]]?
      @belongs_to_model = nil
      @belongs_to_tree = nil #: AssociationTree?
      @belongs_to_type = nil #: String?
      @belongs_to_path = nil #: String?
      @belongs_to_routes = nil #: Array[Array[untyped]]?
    end

    #: (untyped, AssociationTree, String, ?path: String) -> Array[Array[untyped]]
    def collection_routes(model_class, tree, target_type, path: '')
      cached = @collection_routes
      if cached && @collection_model.equal?(model_class) && @collection_tree.equal?(tree) &&
         @collection_type == target_type && @collection_path == path
        return cached
      end

      computed = freeze_routes(routes(model_class, tree, target_type, :has_many, path: path))
      @collection_model = model_class
      @collection_tree = tree
      @collection_type = Support.immutable_copy(target_type)
      @collection_path = Support.immutable_copy(path)
      @collection_routes = computed
    end

    #: (untyped, AssociationTree, String, ?path: String) -> Array[Array[untyped]]
    def belongs_to_routes(model_class, tree, target_type, path: '')
      cached = @belongs_to_routes
      if cached && @belongs_to_model.equal?(model_class) && @belongs_to_tree.equal?(tree) &&
         @belongs_to_type == target_type && @belongs_to_path == path
        return cached
      end

      computed = freeze_routes(routes(model_class, tree, target_type, :belongs_to, path: path))
      @belongs_to_model = model_class
      @belongs_to_tree = tree
      @belongs_to_type = Support.immutable_copy(target_type)
      @belongs_to_path = Support.immutable_copy(path)
      @belongs_to_routes = computed
    end

    private

    # @rbs @traversal: AssociationTraversal
    # @rbs @collection_model: untyped
    # @rbs @collection_tree: AssociationTree?
    # @rbs @collection_type: String?
    # @rbs @collection_path: String?
    # @rbs @collection_routes: Array[Array[untyped]]?
    # @rbs @belongs_to_model: untyped
    # @rbs @belongs_to_tree: AssociationTree?
    # @rbs @belongs_to_type: String?
    # @rbs @belongs_to_path: String?
    # @rbs @belongs_to_routes: Array[Array[untyped]]?

    #: (Array[Array[untyped]]) -> Array[Array[untyped]]
    def freeze_routes(routes)
      routes.each do |route|
        route.each(&:freeze)
        route.freeze
      end.freeze
    end

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
