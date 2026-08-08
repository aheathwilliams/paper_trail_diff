# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Resolves and validates ActiveRecord reflections for a bounded association tree.
  class AssociationTraversal
    #: (AssociationTree) -> void
    def initialize(tree)
      @tree = tree
      @reflection_cache = {}
    end

    #: (untyped) -> void
    def validate!(model_class)
      validate_tree!(model_class, @tree, path: '')
    end

    #: (untyped, AssociationTree, path: String) -> Array[untyped]
    def reflections_for(model_class, tree, path:)
      key = [model_class.name.to_s, path]
      @reflection_cache[key] ||= requested_reflections(model_class, tree, path)
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @reflection_cache: Hash[Array[String], Array[untyped]]

    #: (untyped, AssociationTree, path: String) -> void
    def validate_tree!(model_class, tree, path:)
      reflections_for(model_class, tree, path: path).each do |reflection|
        subtree = tree.child(reflection.name)
        next unless subtree && !subtree.empty? && !reflection.polymorphic?

        child_path = join_path(path, reflection.name.to_s)
        validate_tree!(reflection.klass, subtree, path: child_path)
      end
    end

    #: (untyped, AssociationTree, String) -> Array[untyped]
    def requested_reflections(model_class, tree, path)
      tree.children.map do |name, _subtree|
        resolve_reflection(model_class, name, join_path(path, name))
      end.freeze
    end

    #: (untyped, String, String) -> untyped
    def resolve_reflection(model_class, name, full_path)
      reflection = model_class.reflect_on_association(name.to_sym)
      raise UnknownAssociationError, "unknown association: #{full_path}" unless reflection
      unless %i[belongs_to has_one has_many].include?(reflection.macro)
        raise UnsupportedAssociationError,
              "unsupported association #{full_path}: #{reflection.macro}"
      end

      reflection
    end

    #: (String, String) -> String
    def join_path(parent, name)
      parent.empty? ? name : "#{parent}.#{name}"
    end
  end
end
