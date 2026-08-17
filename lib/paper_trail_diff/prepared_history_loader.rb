# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Expands the explicit association tree into a request-scoped PreparedHistory.
  class PreparedHistoryLoader
    #: (untyped, root_versions: Array[untyped], tree: AssociationTree, traversal: AssociationTraversal, ?root_ids: Array[untyped], ?start_at: untyped, ?end_at: untyped, ?live_records: Array[untyped]) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      record,
      root_versions:,
      tree:,
      traversal:,
      root_ids: [record.id],
      start_at: root_versions.first.created_at,
      end_at: nil,
      live_records: []
    )
      @record = record
      @root_ids = root_ids
      @tree = tree
      @traversal = traversal
      @records = PreparedRecordIndex.new(start_at, end_at: end_at, live_records: live_records)
      @history = PreparedHistory.new(@records)
      @edges = PreparedEdgeLoader.new(@records, root_versions, start_at: start_at)
      @prepared = {} #: Hash[Array[String], Array[String]]
    end

    #: () -> PreparedHistory
    def call
      load_node(@record.class, @root_ids, @tree, path: '')
      @history
    end

    private

    # @rbs @record: untyped
    # @rbs @root_ids: Array[untyped]
    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @records: PreparedRecordIndex
    # @rbs @history: PreparedHistory
    # @rbs @edges: PreparedEdgeLoader
    # @rbs @prepared: Hash[Array[String], Array[String]]

    #: (untyped, Array[untyped], AssociationTree, path: String) -> void
    def load_node(model_class, ids, tree, path:)
      @traversal.reflections_for(model_class, tree, path: path).each do |reflection|
        subtree = tree.child(reflection.name)
        next unless subtree

        groups = prepare_reflection(model_class, ids, reflection)
        load_groups(groups)
        child_path = Support.association_path(path, reflection.name.to_s)
        groups.each_value do |group|
          load_node(group.fetch(:model), group.fetch(:ids), subtree, path: child_path)
        end
      end
    end

    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def prepare_reflection(owner_class, owner_ids, reflection)
      return prepare_through(owner_class, owner_ids, reflection) if reflection.options[:through]

      prepare_edge(owner_class, owner_ids, reflection)
    end

    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def prepare_through(owner_class, owner_ids, reflection)
      through_groups = prepare_edge(owner_class, owner_ids, reflection.through_reflection)
      targets = {} #: Hash[String, Hash[Symbol, untyped]]
      through_groups.each_value do |group|
        load_groups({ group.fetch(:model).name.to_s => group })
        source = prepare_edge(group.fetch(:model), group.fetch(:ids), reflection.source_reflection)
        targets = merge_groups(targets, source)
      end
      @history.merge_edge(owner_class, reflection, targets)
      @history.mark_unsupported(owner_class, reflection) if deferred_macro?(reflection)
      targets
    end

    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def prepare_edge(owner_class, owner_ids, reflection)
      missing = unprepared_ids(owner_class, owner_ids, reflection)
      return @history.edge(owner_class, reflection) if missing.empty?

      load_records(owner_class, missing) if reflection.macro == :belongs_to
      groups, memberships = @edges.call(owner_class, missing, reflection)
      @history.merge_edge(owner_class, reflection, groups)
      @history.register_habtm(owner_class, reflection, memberships) if memberships
      mark_prepared(owner_class, missing, reflection)
      mark_unsupported(owner_class, reflection, groups)
      load_groups(groups)
      @history.edge(owner_class, reflection)
    end

    #: (untyped, Array[untyped], untyped) -> Array[untyped]
    def unprepared_ids(owner_class, ids, reflection)
      prepared = @prepared.fetch(edge_key(owner_class, reflection), [])
      ids.reject { |id| prepared.include?(id.to_s) }
    end

    #: (untyped, Array[untyped], untyped) -> void
    def mark_prepared(owner_class, ids, reflection)
      key = edge_key(owner_class, reflection)
      @prepared[key] = (@prepared.fetch(key, []) | ids.map(&:to_s))
    end

    #: (untyped, untyped, Hash[String, Hash[Symbol, untyped]]) -> void
    def mark_unsupported(owner_class, reflection, groups)
      unsupported = deferred_macro?(reflection) || reflection.foreign_key.is_a?(Array) ||
                    groups.values.any? { |group| !versioned?(group.fetch(:model)) }
      @history.mark_unsupported(owner_class, reflection) if unsupported
    end

    #: (untyped) -> bool
    def deferred_macro?(reflection)
      reflection.options[:through] && !reflection.source_reflection.belongs_to?
    end

    #: (Hash[String, Hash[Symbol, untyped]]) -> void
    def load_groups(groups)
      groups.each_value { |group| load_records(group.fetch(:model), group.fetch(:ids)) }
    end

    #: (untyped, Array[untyped]) -> void
    def load_records(model_class, ids)
      @records.load(model_class, ids) if versioned?(model_class)
    end

    #: (untyped) -> bool
    def versioned?(model_class)
      Support.versioned?(model_class)
    end

    #: (untyped, untyped) -> Array[String]
    def edge_key(owner_class, reflection)
      [owner_class.base_class.name.to_s, reflection.name.to_s]
    end

    #: (Hash[String, Hash[Symbol, untyped]], Hash[String, Hash[Symbol, untyped]]) -> Hash[String, Hash[Symbol, untyped]]
    def merge_groups(left, right)
      Support.merge_record_groups(left, right)
    end
  end
end
