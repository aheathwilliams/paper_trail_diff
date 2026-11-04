# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Expands the explicit association tree into a request-scoped PreparedHistory.
  class PreparedHistoryLoader
    # Without `end_at`, the activity range closes on the last root version.
    # A `window` is a time range; a range of versions starts at the state its
    # first version names. `opening` names the transactions that crossed the
    # window's start when this history is read again from where they began.
    #: (untyped, root_ids: Array[untyped], root_versions: Array[untyped], tree: AssociationTree, traversal: AssociationTraversal, start_at: untyped, end_at: untyped, live_records: Array[untyped], ?window: bool, ?opening: Array[Array[untyped]]) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      record,
      root_ids:,
      root_versions:,
      tree:,
      traversal:,
      start_at:,
      end_at:,
      live_records:,
      window: false,
      opening: []
    )
      @window = window
      @record = record
      @root_ids = root_ids
      @root_versions = root_versions
      @tree = tree
      @traversal = traversal
      @end_at = end_at
      @live_records = live_records
      start_at = VersionBoundary.transaction_start(root_versions, start_at)
      @records = PreparedRecordIndex.new(start_at, end_at: end_at, live_records: live_records)
      @activity = PreparedActivityIndex.new(@records, root_versions, start_at: start_at)
      @history = PreparedHistory.new(@records, activity_index: @activity,
                                               opening_transactions: opening)
      @edges = PreparedEdgeLoader.new(@records, root_versions, children: @activity.children)
      @prepared = {} #: Hash[untyped, Set[String]]
    end

    #: () -> PreparedHistory
    def call
      @records.seed(@record.class, @root_ids, @root_versions)
      load_node(@record.class, @root_ids, @tree, path: '')
      opening = @records.opening if @window
      return @history unless opening

      reload(*opening)
    end

    private

    # @rbs @window: bool
    # @rbs @end_at: untyped
    # @rbs @live_records: Array[untyped]
    # @rbs @record: untyped
    # @rbs @root_ids: Array[untyped]
    # @rbs @root_versions: Array[untyped]
    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @records: PreparedRecordIndex
    # @rbs @activity: PreparedActivityIndex
    # @rbs @history: PreparedHistory
    # @rbs @edges: PreparedEdgeLoader
    # @rbs @prepared: Hash[untyped, Set[String]]

    # A transaction that crosses a window's start and saved a version of the
    # root moves the window's edge back to where it began (see
    # TransactionCut); one that saved only associated records moves nothing.
    # A boundary in such a transaction still reads each record as it stood
    # before the transaction began (see PreparedRecordSeries#boundary_index),
    # and a history read from the window's start holds neither the versions
    # it saved before the start nor the records only those versions name, such
    # as one it destroyed there. Without them the window would start after
    # changes that the window before it left to this one, by ending its step
    # at one of the transaction's events here (see ActivityTreeFilter), and
    # neither would report them. So the history is read again from where the
    # earliest such transaction began; the window's events still start at its
    # start.
    #: (Array[Array[untyped]], untyped) -> PreparedHistory
    def reload(keys, earliest)
      PreparedHistoryLoader.new(
        @record, root_ids: @root_ids, root_versions: @root_versions, tree: @tree,
                 traversal: @traversal, start_at: earliest, end_at: @end_at,
                 live_records: @live_records, opening: keys
      ).call
    end

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
    # read, so each part is prepared as what it is. Like an edge, it returns
    # every group it holds, not only those of these owners.
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
      prepared = @prepared.fetch(reflection) { Set.new }
      ids.reject { |id| prepared.include?(id.to_s) }
    end

    #: (Array[untyped], untyped) -> void
    def mark_prepared(ids, reflection)
      (@prepared[reflection] ||= Set.new).merge(ids.map(&:to_s))
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
