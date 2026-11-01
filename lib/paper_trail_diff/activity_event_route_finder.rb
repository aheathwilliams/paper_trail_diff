# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Finds explicitly selected collection and belongs-to routes for one event type.
  class ActivityEventRouteFinder
    #: (AssociationTraversal) -> void
    def initialize(traversal)
      @traversal = traversal
      @collection_routes = {} #: Hash[Array[untyped], Array[Array[untyped]]]
      @belongs_to_routes = {} #: Hash[Array[untyped], Array[Array[untyped]]]
      @through_parts = {} #: Hash[Array[untyped], bool]
    end

    #: (untyped, AssociationTree, String, ?path: String) -> Array[Array[untyped]]
    def collection_routes(model_class, tree, target_type, path: '')
      cached(@collection_routes, model_class, tree, target_type, path, :has_many)
    end

    #: (untyped, AssociationTree, String, ?path: String) -> Array[Array[untyped]]
    def belongs_to_routes(model_class, tree, target_type, path: '')
      cached(@belongs_to_routes, model_class, tree, target_type, path, :belongs_to)
    end

    # Whether a has_many through in the tree joins through, or reaches,
    # records of the type. Its membership follows their keys, which a route
    # to the record elsewhere in the tree does not update.
    #: (untyped, AssociationTree, String) -> bool
    def through_part?(model_class, tree, target_type)
      key = [model_class, tree, target_type]
      return @through_parts[key] if @through_parts.key?(key)

      @through_parts[key] = through_part_below?(model_class, tree, target_type, '')
    end

    private

    # @rbs @traversal: AssociationTraversal
    # @rbs @collection_routes: Hash[Array[untyped], Array[Array[untyped]]]
    # @rbs @belongs_to_routes: Hash[Array[untyped], Array[Array[untyped]]]
    # @rbs @through_parts: Hash[Array[untyped], bool]

    #: (untyped, AssociationTree, String, String) -> bool
    def through_part_below?(model_class, tree, target_type, path)
      @traversal.reflections_for(model_class, tree, path: path).any? do |reflection|
        next true if through_reaches?(reflection, target_type)

        subtree = tree.child(reflection.name.to_s) #: AssociationTree
        child_path = Support.association_path(path, reflection.name)
        !reflection.polymorphic? && !subtree.empty? &&
          through_part_below?(reflection.klass, subtree, target_type, child_path)
      end
    end

    #: (untyped, String) -> bool
    def through_reaches?(reflection, target_type)
      reflection.through_reflection? &&
        reflection.chain.any? { |part| part.klass.base_class.name.to_s == target_type }
    end

    # Timelines interleave event types, so every requested combination is
    # retained. Model, tree, and path are fixed per adapter, leaving one entry
    # per selected item type.
    #: (Hash[Array[untyped], Array[Array[untyped]]], untyped, AssociationTree, String, String, Symbol) -> Array[Array[untyped]]
    def cached(store, model_class, tree, target_type, path, macro) # rubocop:disable Metrics/ParameterLists
      key = [model_class, tree, target_type, path]
      existing = store[key]
      return existing if existing

      store[cache_key(key)] =
        freeze_routes(routes(model_class, tree, target_type, macro, path: path))
    end

    #: (Array[untyped]) -> Array[untyped]
    def cache_key(key)
      key.map { |part| part.is_a?(String) ? -part : part }.freeze
    end

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
      # Validation rejects a path that continues past a polymorphic target.
      return direct if subtree.empty?

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
