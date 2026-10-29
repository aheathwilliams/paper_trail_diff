# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Resolves and validates ActiveRecord reflections for a bounded association tree.
  class AssociationTraversal
    # The class a `belongs_to` points at for this record, reading a polymorphic
    # type column when there is one. Nil when the record points at nothing.
    #: (untyped, untyped) -> untyped
    def self.belongs_to_target(reflection, record)
      return reflection.klass unless reflection.polymorphic?

      type = record.public_send(reflection.foreign_type).to_s
      polymorphic_target(reflection, record, type) unless type.empty?
    end

    # The class a stored type names, or nil when it names none. The one
    # mutation left, `self.const_get`, also searches Object, so it answers the
    # same for every stored type.
    # mutant:disable
    #: (String) -> untyped
    def self.named_class(type)
      Object.const_get(type)
    rescue NameError
      nil
    end

    # A type left by a renamed or removed model names no class. Active Record
    # and PT-AT raise a bare NameError for it, which does not say where it is.
    #: (untyped, untyped, String) -> untyped
    def self.polymorphic_target(reflection, record, type)
      model_class = named_class(type)
      return model_class if model_class

      raise IncompleteAssociationHistoryError,
            "association #{record.class.name}##{reflection.name} cannot be read: " \
            "#{record.class.name} #{record.id} has #{reflection.foreign_type} #{type}, which " \
            'names no class. If the model was renamed, replace the old name in that column ' \
            'and in the versions that recorded it.'
    end
    private_class_method :polymorphic_target

    attr_reader :tree #: AssociationTree

    # Whether a row belongs to an association whose class is `model_class`.
    # Children are found by key across the whole table, so an association to an
    # STI subclass has to leave out its siblings, as Active Record's type
    # condition does for the live association: the row's type must name the
    # class or one of its descendants. A base class takes every row.
    #: (untyped, Hash[String, untyped]) -> bool
    def self.sti_member?(model_class, attributes)
      return true if model_class.descends_from_active_record?

      names = [model_class, *model_class.descendants].map(&:sti_name)
      names.include?(attributes[model_class.inheritance_column])
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

    # The path only names an association in an error, so it is not part of
    # what is cached.
    #: (untyped, AssociationTree, path: String) -> Array[untyped]
    def reflections_for(model_class, tree, path:)
      @reflection_cache[[model_class, tree.object_id]] ||=
        requested_reflections(model_class, tree, path)
    end

    # A polymorphic child (`as:`) also names its owner's class in a type column.
    #: (untyped) -> Array[String]
    def incoming_relationship_columns(reflection)
      direct = %i[has_one has_many].include?(reflection.macro) && !reflection.through_reflection?
      return [] unless direct

      foreign_keys = Array(reflection.foreign_key)
      # @type var foreign_keys: Array[untyped]
      columns = foreign_keys.map do |column| # rubocop:disable Style/SymbolProc
        column.to_s
      end
      columns << reflection.type if reflection.type
      columns
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @reflection_cache: Hash[Array[untyped], Array[untyped]]

    # A polymorphic target's class is known only per record, so listing stops
    # there; validation rejects a path that continues past it.
    #: (untyped, AssociationTree, path: String) -> Array[Array[untyped]]
    def collect_reflections(model_class, tree, path:)
      reflections_for(model_class, tree, path: path).flat_map do |reflection|
        child_path = join_path(path, reflection.name)
        found = [[child_path, reflection]]
        next found if reflection.polymorphic?

        subtree = tree.children.fetch(reflection.name.to_s)
        found + collect_reflections(reflection.klass, subtree, path: child_path)
      end
    end

    #: (untyped, AssociationTree, path: String) -> void
    def validate_tree!(model_class, tree, path:)
      reflections_for(model_class, tree, path: path).each do |reflection|
        subtree = tree.children.fetch(reflection.name.to_s)
        next if subtree.empty?

        child_path = join_path(path, reflection.name)
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
      reflection = model_class.reflect_on_association(name)
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

    # A `has_many :through` a HABTM never counts: Active Record builds a HABTM
    # as a hidden `has_many`, which is what its `through_reflection` returns.
    #: (untyped) -> bool
    def habtm_reflection?(reflection)
      reflection.macro == :has_and_belongs_to_many
    end

    #: (String, String | Symbol) -> String
    def join_path(parent, name)
      parent.empty? ? name.to_s : "#{parent}.#{name}"
    end
  end
end
