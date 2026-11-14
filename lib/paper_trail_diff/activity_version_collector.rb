# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Collects root and selected-descendant versions relevant to one root history range.
  # Descendants are found in the root's prepared history.
  class ActivityVersionCollector
    # `traversal` holds the tree whose descendants are collected.
    #: (untyped, root_versions: Array[untyped], traversal: AssociationTraversal, range_start: untyped, range_end: untyped, prepared: PreparedActivityIndex?) -> void
    def initialize(record, root_versions:, traversal:, range_start:, range_end:, prepared:) # rubocop:disable Metrics/ParameterLists
      # Only a tree's descendants are read from it, and a tree is always read
      # with prepared history (see HistoricalSnapshotStore#prepare).
      @prepared = prepared #: PreparedActivityIndex
      @record = record
      @root_versions = root_versions
      @traversal = traversal
      @range = ActivityRange.new(range_start, range_end)
      @registry = ActivityEventRegistry.new
    end

    # A tie between version tables, or between ids that do not count up,
    # raises rather than building a timeline in an arbitrary order. The events
    # are in the order their transactions end (see TransactionEnds).
    #: () -> Array[ActivityEvent]
    def call
      @registry.add(@root_versions)
      tree = @traversal.tree
      unless tree.empty?
        collect_tree(group(@record.class, [@record.id]), tree, path: '', branch: nil)
      end
      ordered(@registry.to_a)
    end

    # Where the transactions of the collected events take effect, once #call
    # has ordered them by it.
    #: () -> TransactionEnds?
    attr_reader :ends

    private

    # @rbs @prepared: PreparedActivityIndex
    # @rbs @record: untyped
    # @rbs @root_versions: Array[untyped]
    # @rbs @traversal: AssociationTraversal
    # @rbs @range: ActivityRange
    # @rbs @registry: ActivityEventRegistry
    # @rbs @ends: TransactionEnds?

    #: (Array[ActivityEvent]) -> Array[ActivityEvent]
    def ordered(events)
      events = events.sort_by { |event| Support.chronological_version_key(event.version) }
      pair = Support.ambiguous_pair(events.map(&:version))
      raise(AmbiguousVersionOrderError, Support.ambiguous_message(pair)) if pair

      ends = transaction_ends(events.map(&:version))
      events.sort_by { |event| ends.sort_key(event.version) }.freeze
    end

    #: (Array[untyped]) -> TransactionEnds
    def transaction_ends(versions)
      prepared = @prepared #: PreparedActivityIndex?
      @ends = prepared ? prepared.transaction_ends(versions) : TransactionEnds.new(versions)
    end

    # Each event is credited to the top-level association it was reached
    # through.
    #: (Hash[Symbol, untyped], AssociationTree, path: String, branch: String?) -> void
    def collect_tree(parent, tree, path:, branch:)
      @traversal.reflections_for(parent.fetch(:model), tree, path: path).each do |reflection|
        # Each reflection is of a child the tree names.
        subtree = tree.child(reflection.name) #: AssociationTree
        collect_reflection(parent, reflection, subtree, path, branch || reflection.name.to_s)
      end
    end

    #: (Hash[Symbol, untyped], untyped, AssociationTree, String, String) -> void
    def collect_reflection(parent, reflection, subtree, path, branch)
      edge_groups(parent, reflection, branch).each do |group|
        @registry.add(group.fetch(:versions), branch: branch)
        collect_tree(group, subtree, path: Support.association_path(path, reflection.name),
                                     branch: branch)
      end
    end

    # The groups of records an edge leads to, one for each class.
    #: (Hash[Symbol, untyped], untyped, String) -> Array[Hash[Symbol, untyped]]
    def edge_groups(parent, reflection, branch)
      return through_groups(parent, reflection, branch) if reflection.through_reflection?

      if reflection.belongs_to?
        belongs_to_groups(parent.fetch(:model), parent.fetch(:ids), reflection)
      else
        direct_child_groups(parent.fetch(:model), parent.fetch(:ids), reflection)
      end
    end

    # A through's join part is one class, never polymorphic, so one group of
    # join rows leads to its targets.
    #: (Hash[Symbol, untyped], untyped, String) -> Array[Hash[Symbol, untyped]]
    def through_groups(parent, reflection, branch)
      targets = edge_groups(parent, reflection.through_reflection, branch).flat_map do |group|
        joins = @prepared.join_versions(parent, group, reflection)
        @registry.add(joins, branch: branch, join: true)
        led(group, reflection, edge_groups(group, reflection.source_reflection, branch))
      end
      # Under `source_type:`, only targets of that type are members.
      type = reflection.options[:source_type]
      type ? targets.select { |group| type.to_s.eql?(group.fetch(:model).name) } : targets
    end

    # The targets a through reaches by a `belongs_to` name the join rows that
    # lead to them, which judge them as join rows of a through over this one
    # (see PreparedActivityIndex#join_versions).
    #: (Hash[Symbol, untyped], untyped, Array[Hash[Symbol, untyped]]) -> Array[Hash[Symbol, untyped]]
    def led(rows, reflection, targets)
      return targets unless reflection.source_reflection.belongs_to?

      targets.map { |target| target.merge(leads: { group: rows, reflection: reflection }) }
    end

    # Every target the owners pointed at in the range, not only those their own
    # changes there recorded: an author renamed under an article nobody edited
    # is still that article's activity. Prepared history holds every target its
    # snapshots can contain. One it did not load -- a key changed without a
    # version -- has no state to compare.
    #: (untyped, Array[untyped], untyped) -> Array[Hash[Symbol, untyped]]
    def belongs_to_groups(parent_class, parent_ids, reflection)
      rows = @prepared.target_rows(parent_class, parent_ids, reflection)
      identities = rows.group_by do |row|
        AssociationTraversal.stored_target(reflection, row.foreign_type)
      end
      identities.filter_map do |model_class, class_rows|
        next unless model_class

        ids = target_ids(class_rows).select { |id| @prepared.loaded?(model_class, id) }
        group(model_class, ids)
      end
    end

    #: (untyped, Array[untyped], untyped) -> Array[Hash[Symbol, untyped]]
    def direct_child_groups(parent_class, parent_ids, reflection)
      [group(reflection.klass, @prepared.child_ids(parent_class, parent_ids, reflection, @range))]
    end

    # Each target once, however many rows name it, and none for a row that
    # names none. The registry keeps a version once, and a missing target has
    # no versions, so this only saves reading them again, which is why mutant
    # leaves it alone.
    # mutant:disable
    #: (Array[untyped]) -> Array[untyped]
    def target_ids(rows)
      rows.filter_map(&:foreign_key_id).uniq
    end

    #: (untyped, Array[untyped]) -> Hash[Symbol, untyped]
    def group(model_class, ids)
      ids = @prepared.member_ids(model_class, ids)
      { model: model_class, ids: ids,
        versions: @prepared.member_versions(model_class, ids, @range) }
    end
  end
end
