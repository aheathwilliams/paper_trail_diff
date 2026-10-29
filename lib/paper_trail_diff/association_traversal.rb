# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Resolves and validates ActiveRecord reflections for a bounded association tree.
  class AssociationTraversal
    # The class a `belongs_to` points at for this record, reading a polymorphic
    # type column when there is one. Nil when that type names no class.
    #: (untyped, untyped) -> untyped
    def self.belongs_to_target(reflection, record)
      return reflection.klass unless reflection.polymorphic?

      Object.const_get(record.public_send(reflection.foreign_type).to_s)
    rescue NameError
      nil
    end

    #: (AssociationTree) -> void
    def initialize(tree)
      @tree = tree
      @reflection_cache = {}
    end

    #: (untyped) -> void
    def validate!(model_class)
      validate_tree!(model_class, @tree, path: '')
    end

    #: (untyped) -> Array[Array[untyped]]
    def selected_reflections(model_class)
      collect_reflections(model_class, @tree, path: '').freeze
    end

    #: (untyped, untyped) -> void
    def ensure_habtm_history!(model_class, version)
      paths = habtm_paths(model_class)
      return if paths.empty?
      return if version.respond_to?(:transaction_id) && version.transaction_id

      message = "HABTM history is incomplete at version #{version.id}: #{paths.join(', ')}"
      raise IncompleteAssociationHistoryError, message
    end

    #: (untyped) -> Array[String]
    def habtm_paths(model_class)
      selected_reflections(model_class).filter_map do |path, reflection|
        path if habtm_reflection?(reflection)
      end.freeze
    end

    # HABTM join rows have no versions of their own, so membership changes
    # cannot be split into events once a range runs past the last root version
    # into live state.
    #: (untyped) -> void
    def reject_live_habtm_activity!(model_class)
      paths = habtm_paths(model_class)
      return if paths.empty?

      message = "live-ended activity cannot reconstruct HABTM event boundaries: #{paths.join(', ')}"
      raise UnsupportedLiveActivityError, message
    end

    #: (untyped, AssociationTree, path: String) -> Array[untyped]
    def reflections_for(model_class, tree, path:)
      key = [model_class.name.to_s, path, tree.object_id]
      @reflection_cache[key] ||= requested_reflections(model_class, tree, path)
    end

    #: (untyped) -> Array[String]
    def incoming_relationship_columns(reflection)
      direct = %i[has_one has_many].include?(reflection.macro) && !reflection.options[:through]
      return [] unless direct

      foreign_keys = Array(reflection.foreign_key)
      # @type var foreign_keys: Array[untyped]
      columns = foreign_keys.map do |column| # rubocop:disable Style/SymbolProc
        column.to_s
      end
      columns << reflection.type.to_s if reflection.options[:as]
      columns
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @reflection_cache: Hash[Array[untyped], Array[untyped]]

    #: (untyped, AssociationTree, path: String) -> Array[Array[untyped]]
    def collect_reflections(model_class, tree, path:)
      reflections_for(model_class, tree, path: path).flat_map do |reflection|
        child_path = join_path(path, reflection.name.to_s)
        result = [[child_path, reflection]]
        subtree = tree.child(reflection.name)
        next result unless subtree && !subtree.empty? && !reflection.polymorphic?

        result + collect_reflections(reflection.klass, subtree, path: child_path)
      end
    end

    #: (untyped, AssociationTree, path: String) -> void
    def validate_tree!(model_class, tree, path:)
      reflections_for(model_class, tree, path: path).each do |reflection|
        subtree = tree.child(reflection.name)
        next unless subtree && !subtree.empty?

        child_path = join_path(path, reflection.name.to_s)
        reject_polymorphic_descent!(reflection, subtree, child_path)
        validate_tree!(reflection.klass, subtree, path: child_path)
      end
    end

    # A polymorphic target's class differs from record to record, so the
    # associations a path names below it may not exist on every target.
    #: (untyped, AssociationTree, String) -> void
    def reject_polymorphic_descent!(reflection, subtree, path)
      return unless reflection.polymorphic?

      raise UnsupportedAssociationError,
            "unsupported association #{subtree.paths(prefix: path).first}: " \
            "#{path} is polymorphic, so a path cannot continue past it"
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

      if paper_trail_versions?(model_class, reflection)
        message = "unsupported association #{full_path}: PaperTrail versions"
        raise UnsupportedAssociationError, message
      end
      unless SUPPORTED_ASSOCIATION_MACROS.include?(reflection.macro)
        raise UnsupportedAssociationError,
              "unsupported association #{full_path}: #{reflection.macro}"
      end

      reflection
    end

    #: (untyped, untyped) -> bool
    def paper_trail_versions?(model_class, reflection)
      model_class.respond_to?(:versions_association_name) &&
        reflection.name.to_s == model_class.versions_association_name.to_s
    end

    #: (untyped) -> bool
    def habtm_reflection?(reflection)
      return true if reflection.macro == :has_and_belongs_to_many
      return false unless reflection.options[:through]

      habtm_reflection?(reflection.through_reflection)
    end

    #: (String, String) -> String
    def join_path(parent, name)
      parent.empty? ? name : "#{parent}.#{name}"
    end
  end
end
