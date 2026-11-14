# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Resolves and validates ActiveRecord reflections for a bounded association tree.
  class AssociationTraversal # rubocop:disable Metrics/ClassLength
    # A join table has no versions, so its rows' history cannot be read.
    HABTM_REASON = 'a has_and_belongs_to_many keeps no history of its join rows; ' \
                   'replace it with a has_many :through a join model that has has_paper_trail'

    # The class a `belongs_to` points at for this record, reading a polymorphic
    # type column when there is one. Nil when the record points at nothing.
    #: (untyped, untyped) -> untyped
    def self.belongs_to_target(reflection, record)
      return reflection.klass unless reflection.polymorphic?

      type = record.public_send(reflection.foreign_type).to_s
      polymorphic_target(reflection, record, type) unless type.empty?
    end

    # Whether an unordered has_one through reads the target of its first
    # join row. SQL Server plans the join from the target's table instead, so
    # its LIMIT reads the target with the lowest key, as a plain has_one does.
    #: (untyped) -> bool
    def self.join_order?(reflection)
      return false if reflection.active_record.connection_db_config.adapter == 'sqlserver'

      reflection.through_reflection?
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

    # Every part a through passes, at any depth: its through part and that
    # part's own parts, then its source part and that part's own parts.
    #: (untyped) -> Array[untyped]
    def self.through_parts(reflection)
      return [] unless reflection.through_reflection?

      [reflection.through_reflection, reflection.source_reflection].flat_map do |part|
        [part, *through_parts(part)]
      end
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

    # The class a belongs_to's target is, given the type a polymorphic one
    # stored: nil when that names no class.
    #: (untyped, untyped) -> untyped
    def self.stored_target(reflection, type)
      return reflection.klass unless reflection.polymorphic?

      named_class(type.to_s)
    end

    # The type an `as:` child stores for its owner. Active Record reads only
    # this one, its owner's polymorphic name, which an STI subclass shares
    # with its base class; a child typed with a subclass's name is no member.
    # The declaring class shares the owner's base class, so it names it.
    #: (untyped) -> String
    def self.owner_type(reflection)
      reflection.active_record.polymorphic_name
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
    # can. Discovery lists only the associations this accepts, so every path
    # it lists can be requested. A has_many :through Active Record cannot
    # follow raises Active Record's own error.
    #: (untyped, untyped) -> String?
    def self.unsupported_reason(model_class, reflection)
      return 'PaperTrail versions' if paper_trail_versions?(model_class, reflection)
      return HABTM_REASON if reflection.macro == :has_and_belongs_to_many
      return reflection.macro.to_s unless SUPPORTED_ASSOCIATION_MACROS.include?(reflection.macro)

      habtm = habtm_in_chain(reflection)
      return storage_reason(reflection) unless habtm

      "it goes through #{habtm.active_record.name}##{habtm.name}, a has_and_belongs_to_many, " \
        'whose hidden join model has no history to compare'
    end

    # History matches records by primary key, within one set of version
    # tables, and finds a child's owner where the child's versions recorded it.
    #: (untyped) -> String?
    def self.storage_reason(reflection)
      AssociationKey.unsupported_reason(reflection) ||
        VersionTable.unsupported_reason(reflection) || RecordedOwner.unsupported_reason(reflection)
    end
    private_class_method :storage_reason

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
      @reaches = {} #: Hash[[untyped, untyped], untyped]
    end

    # Where the earliest transaction open at `start` began, in the version
    # tables of the model and of the records on its paths; nil when none was
    # open, without a start, or without paths (see CrossingTransactions). A
    # call reads every root of a model from one answer, so it is asked once.
    #: (untyped, untyped) -> untyped
    def reach_before(model_class, start)
      return if @tree.empty? || start.nil?

      key = [model_class, start] #: [untyped, untyped]
      return @reaches[key] if @reaches.key?(key)

      @reaches[key] = CrossingTransactions.open_around(model_class, self, start)
    end

    #: (untyped) -> void
    def validate!(model_class)
      validate_tree!(model_class, @tree, path: '')
    end

    #: (untyped) -> Array[Array[untyped]]
    def selected_reflections(model_class)
      collect_reflections(model_class, @tree, path: '').freeze
    end

    # The names the versions of the records on the requested paths are stored
    # under: each association's class and every part a through passes. A
    # polymorphic belongs_to names its target's class only in each record, so
    # it adds none (see #polymorphic_paths?).
    #: (untyped) -> Array[String]
    def path_types(model_class)
      path_parts(model_class).reject(&:polymorphic?).map { |part| part.klass.base_class.name }.uniq
    end

    # Whether a path passes a polymorphic belongs_to, whose targets may be of
    # any class.
    #: (untyped) -> bool
    def polymorphic_paths?(model_class)
      path_parts(model_class).any?(&:polymorphic?)
    end

    #: (untyped) -> Array[untyped]
    def path_parts(model_class)
      selected_reflections(model_class).flat_map do |_path, reflection|
        [reflection, *self.class.through_parts(reflection)]
      end
    end
    private :path_parts

    # A model and a tree resolve to the same reflections wherever they are
    # read: a tree is only ever walked from one place, the root tree at the
    # root and a subtree below it. Beyond that, the path only names a failure,
    # and a failure is not cached. Each record is read at every boundary, so
    # the lookup builds no key.
    #: (untyped, AssociationTree, path: String) -> Array[untyped]
    def reflections_for(model_class, tree, path:)
      by_class = @reflection_cache[tree] ||= {}
      by_class[model_class] ||= requested_reflections(model_class, tree, path)
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
    # @rbs @reflection_cache: Hash[AssociationTree, Hash[untyped, Array[untyped]]]

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
        resolve_reflection(model_class, name, Support.association_path(path, name))
      end.freeze
    end

    #: (untyped, String, String) -> untyped
    def resolve_reflection(model_class, name, full_path)
      reflection = model_class.reflect_on_association(name)
      raise UnknownAssociationError, "unknown association: #{full_path}" unless reflection

      reason = self.class.unsupported_reason(model_class, reflection)
      raise UnsupportedAssociationError, "unsupported association #{full_path}: #{reason}" if reason

      reflection
    end
  end
end
