# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Expands the explicit association tree into a request-scoped PreparedHistory.
  class PreparedHistoryLoader
    # Without `end_at`, the activity range closes on the last root version.
    #: (untyped, root_ids: Array[untyped], root_versions: Array[untyped], tree: AssociationTree, traversal: AssociationTraversal, start_at: untyped, end_at: untyped, live_records: Array[untyped]) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      record,
      root_ids:,
      root_versions:,
      tree:,
      traversal:,
      start_at:,
      end_at:,
      live_records:
    )
      @record = record
      @root_ids = root_ids
      @root_versions = root_versions
      @tree = tree
      @traversal = traversal
      @records = PreparedRecordIndex.new(start_at, end_at: end_at, live_records: live_records)
      @activity = PreparedActivityIndex.new(
        @records, root_versions, start_at: start_at, end_at: end_at || root_versions.last.created_at
      )
      @history = PreparedHistory.new(@records, activity_index: @activity)
      @edges = PreparedEdgeLoader.new(@records, root_versions, start_at: start_at)
      @prepared = {} #: Hash[untyped, Array[String]]
    end

    #: () -> PreparedHistory
    def call
      @records.seed(@record.class, @root_ids, @root_versions)
      load_node(@record.class, @root_ids, @tree, path: '')
      @history
    end

    private

    # @rbs @record: untyped
    # @rbs @root_ids: Array[untyped]
    # @rbs @root_versions: Array[untyped]
    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @records: PreparedRecordIndex
    # @rbs @activity: PreparedActivityIndex
    # @rbs @history: PreparedHistory
    # @rbs @edges: PreparedEdgeLoader
    # @rbs @prepared: Hash[untyped, Array[String]]

    #: (untyped, Array[untyped], AssociationTree, path: String) -> void
    def load_node(model_class, ids, tree, path:)
      @activity.register(model_class, ids)
      @traversal.reflections_for(model_class, tree, path: path).each do |reflection|
        subtree = tree.child(reflection.name) #: AssociationTree
        groups = prepare_reflection(model_class, ids, reflection)
        child_path = Support.association_path(path, reflection.name)
        groups.each_value do |group|
          load_node(group.fetch(:model), group.fetch(:ids), subtree, path: child_path)
        end
      end
    end

    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def prepare_reflection(owner_class, owner_ids, reflection)
      return prepare_through(owner_class, owner_ids, reflection) if reflection.through_reflection?

      prepare_edge(owner_class, owner_ids, reflection)
    end

    # Either part can itself be a through, which has no key of its own to
    # read, so each part is prepared as what it is.
    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def prepare_through(owner_class, owner_ids, reflection)
      through_groups = prepare_reflection(owner_class, owner_ids, reflection.through_reflection)
      targets = {} #: Hash[String, Hash[Symbol, untyped]]
      through_groups.each_value do |group|
        source = prepare_reflection(group.fetch(:model), group.fetch(:ids),
                                    reflection.source_reflection)
        targets = merge_groups(targets, source)
      end
      @history.merge_edge(owner_class, reflection, targets)
      # Only a belongs_to source is read from prepared history.
      unless reflection.source_reflection.belongs_to?
        @history.mark_unsupported(owner_class, reflection)
      end
      targets
    end

    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def prepare_edge(owner_class, owner_ids, reflection)
      missing = unprepared_ids(owner_ids, reflection)
      return @history.edge(owner_class, reflection) if missing.empty?

      groups, memberships = @edges.call(owner_class, missing, reflection)
      @history.merge_edge(owner_class, reflection, groups)
      @history.register_habtm(owner_class, reflection, memberships) if memberships
      mark_prepared(missing, reflection)
      mark_unsupported(owner_class, reflection, groups)
      load_groups(groups)
      @history.edge(owner_class, reflection)
    end

    # A reflection belongs to the class that declares it, so it alone names
    # the edge; a subclass that inherits it reads the same records.
    #: (Array[untyped], untyped) -> Array[untyped]
    def unprepared_ids(ids, reflection)
      prepared = @prepared.fetch(reflection, [])
      ids.reject { |id| prepared.include?(id.to_s) }
    end

    #: (Array[untyped], untyped) -> void
    def mark_prepared(ids, reflection)
      @prepared[reflection] = (@prepared.fetch(reflection, []) | ids.map(&:to_s))
    end

    #: (untyped, untyped, Hash[String, Hash[Symbol, untyped]]) -> void
    def mark_unsupported(owner_class, reflection, groups)
      unsupported = reflection.foreign_key.is_a?(Array) ||
                    groups.values.any? { |group| !versioned?(group.fetch(:model)) }
      @history.mark_unsupported(owner_class, reflection) if unsupported
    end

    #: (Hash[String, Hash[Symbol, untyped]]) -> void
    def load_groups(groups)
      groups.each_value do |group|
        model = group.fetch(:model)
        ids = group.fetch(:ids)
        @activity.register(model, ids)
        load_records(model, ids)
      end
    end

    #: (untyped, Array[untyped]) -> void
    def load_records(model_class, ids)
      @records.load(model_class, ids) if versioned?(model_class)
    end

    #: (untyped) -> bool
    def versioned?(model_class)
      Support.versioned?(model_class)
    end

    #: (Hash[String, Hash[Symbol, untyped]], Hash[String, Hash[Symbol, untyped]]) -> Hash[String, Hash[Symbol, untyped]]
    def merge_groups(left, right)
      Support.merge_record_groups(left, right)
    end
  end
end
