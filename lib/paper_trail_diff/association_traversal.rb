# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Resolves and validates ActiveRecord reflections for a bounded association tree.
  class AssociationTraversal # rubocop:disable Metrics/ClassLength
    # The class a `belongs_to` points at for this record, reading a polymorphic
    # type column when there is one. Nil when the record points at nothing.
    #: (untyped, untyped) -> untyped
    def self.belongs_to_target(reflection, record)
      return reflection.klass unless reflection.polymorphic?

      type = record.public_send(reflection.foreign_type).to_s
      polymorphic_target(reflection, record, type) unless type.empty?
    end

    # A through with `source_type:` reaches only the join records whose type
    # column names that class, as Active Record's `where(type => source_type)`.
    # A through's `foreign_type` is its polymorphic source's.
    #: (untyped, untyped) -> bool
    def self.source_type_join?(reflection, join)
      reflection.options[:source_type].nil? ||
        source_type_member?(reflection, join.public_send(reflection.foreign_type))
    end

    # The same check for a join row read as stored attributes, given the
    # value of its type column.
    #: (untyped, untyped) -> bool
    def self.source_type_member?(reflection, type)
      source_type = reflection.options[:source_type]
      source_type.nil? || type == source_type.to_s
    end

    # The class a stored type names, or nil when it names none.
    # This class defines no constants of its own, so the one mutation left,
    # `const_get` on it rather than on Object, finds the same class.
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

    # Why a request cannot name this association of the model, or nil when it
    # can; `root` says whether the model is the record the request compares.
    # Discovery lists only the associations this accepts, so every path it
    # lists can be requested. A has_many :through Active Record cannot follow
    # raises Active Record's own error.
    #: (untyped, untyped, root: bool) -> String?
    def self.unsupported_reason(model_class, reflection, root:)
      return 'PaperTrail versions' if paper_trail_versions?(model_class, reflection)
      return reflection.macro.to_s unless SUPPORTED_ASSOCIATION_MACROS.include?(reflection.macro)
      if reflection.macro == :has_and_belongs_to_many
        return habtm_reason(reflection, root) || VersionTable.unsupported_reason(reflection)
      end

      habtm = habtm_in_chain(reflection)
      return storage_reason(reflection) unless habtm

      "it goes through #{habtm.active_record.name}##{habtm.name}, a has_and_belongs_to_many, " \
        'whose hidden join model has no history to compare'
    end

    # History matches records by primary key, within one set of version tables.
    #: (untyped) -> String?
    def self.storage_reason(reflection)
      AssociationKey.unsupported_reason(reflection) || VersionTable.unsupported_reason(reflection)
    end
    private_class_method :storage_reason

    # PT-AT records a HABTM's membership only when its owner saves a version,
    # in rows keyed by transaction and association name, not by owner. A root
    # checkpoint so holds the root's membership and no one else's: another
    # record's HABTM would read the root's rows, or none.
    #: (untyped) -> String
    def self.habtm_below_root(reflection)
      "#{reflection.active_record.name}##{reflection.name} is a has_and_belongs_to_many " \
        'below the root, and a root checkpoint records HABTM membership for the root alone'
    end
    private_class_method :habtm_below_root

    # PT-AT records a HABTM's membership by loading the association, scope and
    # target default scope applied, so a target outside the scope when the
    # owner saved is never recorded. One that enters it before the next save
    # is a member then that history cannot hold.
    #: (untyped, bool) -> String?
    def self.habtm_reason(reflection, root)
      return habtm_below_root(reflection) unless root
      return unless ScopeCondition.scoped?(reflection)

      "#{reflection.active_record.name}##{reflection.name} is a scoped " \
        'has_and_belongs_to_many, and PaperTrail records only the members its scope ' \
        'admitted when the owner saved, so membership between saves cannot be rebuilt; ' \
        'replace it with a has_many :through a versioned join model'
    end
    private_class_method :habtm_reason

    #: (untyped, untyped) -> bool
    def self.paper_trail_versions?(model_class, reflection)
      model_class.respond_to?(:versions_association_name) &&
        reflection.name.to_s == model_class.versions_association_name.to_s
    end
    private_class_method :paper_trail_versions?

    # Active Record joins a HABTM through a hidden model of its own, which has
    # no versions and no reader that PT-AT or prepared history can follow, so a
    # through that crosses one would fail partway through reconstruction.
    #
    # The through and source reflections of a through are the hidden ones, a
    # has_many in place of each HABTM, so only the public reflection of the
    # same name shows the HABTM. Active Record's own check, which it runs on
    # first use anyway, explains a through it cannot follow before the chain
    # below it is read.
    #: (untyped) -> untyped
    def self.habtm_in_chain(reflection)
      return unless reflection.through_reflection?

      reflection.check_validity!
      parts = [reflection.through_reflection, reflection.source_reflection]
      parts.filter_map do |part|
        link = part.active_record.reflect_on_association(part.name)
        link.macro == :has_and_belongs_to_many ? link : habtm_in_chain(link)
      end.first
    end
    private_class_method :habtm_in_chain

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

    # A model and a tree resolve to the same reflections wherever they are
    # read: a tree is only ever walked from one place, the root tree at the
    # root and a subtree below it. Beyond that, the path only names a failure,
    # and a failure is not cached.
    #: (untyped, AssociationTree, path: String) -> Array[untyped]
    def reflections_for(model_class, tree, path:)
      @reflection_cache[[model_class, tree]] ||= requested_reflections(model_class, tree, path)
    end

    # Active Record names keys as strings. A polymorphic child also points back
    # with its type column; `type` is nil for any other.
    #: (untyped) -> Array[String]
    def incoming_relationship_columns(reflection)
      direct = %i[has_one has_many].include?(reflection.macro) && !reflection.through_reflection?
      return [] unless direct

      Array(reflection.foreign_key) + Array(reflection.type)
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @reflection_cache: Hash[Array[untyped], Array[untyped]]

    #: (untyped, AssociationTree, path: String) -> Array[Array[untyped]]
    def collect_reflections(model_class, tree, path:)
      reflections_for(model_class, tree, path: path).flat_map do |reflection|
        child_path = Support.association_path(path, reflection.name)
        result = [[child_path, reflection]]
        next result if reflection.polymorphic?

        # A leaf's subtree is empty and adds nothing.
        subtree = tree.child(reflection.name) #: AssociationTree
        result + collect_reflections(reflection.klass, subtree, path: child_path)
      end
    end

    #: (untyped, AssociationTree, path: String) -> void
    def validate_tree!(model_class, tree, path:)
      reflections_for(model_class, tree, path: path).each do |reflection|
        subtree = tree.child(reflection.name) #: AssociationTree
        next if subtree.empty?

        child_path = Support.association_path(path, reflection.name)
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
        resolve_reflection(model_class, name, Support.association_path(path, name),
                           root: path.empty?)
      end.freeze
    end

    #: (untyped, String, String, root: bool) -> untyped
    def resolve_reflection(model_class, name, full_path, root:)
      reflection = model_class.reflect_on_association(name)
      raise UnknownAssociationError, "unknown association: #{full_path}" unless reflection

      reason = self.class.unsupported_reason(model_class, reflection, root: root)
      raise UnsupportedAssociationError, "unsupported association #{full_path}: #{reason}" if reason

      reflection
    end

    #: (untyped) -> bool
    def habtm_reflection?(reflection)
      reflection.macro == :has_and_belongs_to_many
    end
  end
end
