# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Finds the roots whose requested associations changed in a window, so that
  # selecting by activity includes a record whose own row did not change.
  #
  # A root qualifies when a record on one of its requested paths has a version
  # in the window while it belonged to that root: when the window opened, or
  # after a change inside it. Those are the memberships PT-AT recorded, and the
  # ones an activity analysis reads. For `has_many :through`, the join rows are
  # on the path too, since creating or destroying one changes membership.
  #
  # Each edge is one query, walked from the leaves toward the root, never one
  # per root. Ids stay in a subquery while the columns compared share a type;
  # otherwise they are read and the edge runs over them in slices.
  class AssociationActivitySelection
    # The ids a one-column subquery selects, with that column's type: a
    # database compares columns of one type only, and PostgreSQL rejects an
    # integer key against a string item_id outright.
    class Query
      attr_reader :relation #: untyped
      attr_reader :column #: untyped
      attr_reader :type #: Symbol?

      #: (untyped, untyped, Symbol?) -> void
      def initialize(relation, column, type)
        @relation = relation.select(column)
        @column = column
        @type = type
        freeze
      end

      # A key PT-AT recorded as empty names no record, so it is left out.
      #: () -> Array[untyped]
      def values
        @relation.distinct.pluck(@column).compact
      end

      # The ids no row of the model has for its key, whatever scope the model
      # has by default. They are asked for with NOT EXISTS: PostgreSQL does
      # not plan `NOT IN (SELECT ...)` as an anti-join, so it reads every key
      # of the table for the statement, and again for each id once the keys
      # outgrow its working memory. An empty key names no record.
      #: (untyped) -> Array[untyped]
      def missing(model)
        key = model.arel_table[model.primary_key]
        rows = model.unscoped.where(key.eq(@column)).arel.exists
        @relation.where(rows.not).distinct.pluck(@column).compact
      end
    end

    # @rbs!
    #   type source = Query | Array[untyped]

    # Every id the sources name, read from the database where needed.
    #: (Array[source]) -> Array[untyped]
    def self.values(sources)
      sources.flat_map { |ids| ids.is_a?(Query) ? ids.values : ids }.uniq
    end

    # The window roots are selected over: the one asked for, and with a tree,
    # from where the earliest transaction open at its start began (see
    # SelectionWindow). A window reports such a transaction, which may have
    # saved a root's tree only before it.
    #: (untyped, AssociationTraversal?, TimeRange?) -> TimeRange?
    def self.window(model, traversal, range)
      return range unless range && traversal

      reach = traversal.reach_before(model, range.begin_time)
      reach ? SelectionWindow.new(range, reach) : range
    end

    # Only the versions `version_scope` keeps select a root, on its
    # associations as on its own versions.
    #: (untyped, traversal: AssociationTraversal, time_range: TimeRange?, ?version_scope: untyped) -> void
    def initialize(model, traversal:, time_range:, version_scope: nil)
      @model = model
      @traversal = traversal
      @time_range = time_range
      @version_scope = version_scope
    end

    # The roots' ids, each source a subquery or an array of values.
    #: () -> Array[source]
    def call
      reach(@model, @traversal.tree, '')
    end

    private

    # @rbs @model: untyped
    # @rbs @traversal: AssociationTraversal
    # @rbs @time_range: TimeRange?
    # @rbs @version_scope: untyped

    # Ids of `model` records with a change somewhere below them in `tree`: the
    # targets that changed, or that reach a change further down.
    #: (untyped, AssociationTree, String) -> Array[source]
    def reach(model, tree, path)
      @traversal.reflections_for(model, tree, path: path).flat_map do |reflection|
        next polymorphic_owners(reflection) if reflection.polymorphic?

        target = reflection.klass
        subtree = tree.child(reflection.name) #: AssociationTree
        child_path = Support.association_path(path, reflection.name)
        owners(reflection, changed(target) + reach(target, subtree, child_path))
      end
    end

    #: (untyped, Array[source]) -> Array[source]
    def owners(reflection, ids)
      return [] if ids.empty?
      return through_owners(reflection, ids) if reflection.through_reflection?

      edges(reflection).flat_map { |edge| follow(edge, ids) }
    end

    # A join row that changes moves membership as surely as a target that does.
    #: (untyped, Array[source]) -> Array[source]
    def through_owners(reflection, ids)
      through = reflection.through_reflection
      source_type = reflection.options[:source_type]
      joins = if source_type
                typed_joins(reflection, ids, source_type)
              else
                owners(reflection.source_reflection, ids) + changed(through.klass)
              end
      owners(through, joins)
    end

    # Under `source_type:`, only join rows of that type are members, so only
    # targets of that type and changes to those rows count.
    #: (untyped, Array[source], untyped) -> Array[source]
    def typed_joins(reflection, ids, source_type)
      edge = AssociationActivityEdge::BelongsTo.new(reflection.source_reflection, @time_range,
                                                    foreign_type: source_type)
      follow(edge, ids) + changed(reflection.through_reflection.klass, edge.typed_owners)
    end

    # A polymorphic key's targets are known only from the types its rows name,
    # and a path stops at one, so only the targets' own changes count.
    #: (untyped) -> Array[source]
    def polymorphic_owners(reflection)
      edge = AssociationActivityEdge::BelongsTo.new(reflection, @time_range)
      edge.target_types.flat_map do |name|
        typed = AssociationActivityEdge::BelongsTo.new(reflection, @time_range, foreign_type: name)
        follow(typed, changed(AssociationTraversal.named_class(name)))
      end
    end

    #: (untyped) -> Array[AssociationActivityEdge]
    def edges(reflection)
      kinds = case reflection.macro
              when :belongs_to then [AssociationActivityEdge::BelongsTo]
              when :has_and_belongs_to_many
                [AssociationActivityEdge::LiveHabtm, AssociationActivityEdge::RecordedHabtm]
              else [AssociationActivityEdge::Child, AssociationActivityEdge::Unversioned]
              end
      kinds.map { |kind| kind.new(reflection, @time_range) }.select(&:available?)
    end

    # Records with a version in the window, or only those of them `item_ids`
    # selects: under `source_type:`, the join rows that had that type.
    #: (untyped, ?untyped) -> Array[source]
    def changed(model, item_ids = nil)
      return [] unless Support.versioned?(model)

      versions = model.paper_trail.version_class
      relation = item_ids ? VersionQuery.for_items(model, item_ids) : VersionQuery.for_model(model)
      range = @time_range
      relation = range.scope(relation) if range
      relation = VersionScopeFilter.whole_transactions(@version_scope, relation) if @version_scope
      [Query.new(relation, versions.arel_table[:item_id],
                 versions.type_for_attribute('item_id').type)]
    end

    # One edge for each source. A subquery whose column type matches the
    # filtered column stays a subquery; anything else is read, and the edge
    # runs over its values in slices.
    #: (AssociationActivityEdge, Array[source]) -> Array[source]
    def follow(edge, sources)
      sources.filter_map do |source|
        query = subquery(source, edge.filter_type)
        next Query.new(edge.relation(query.relation), edge.column, edge.type) if query

        found = read(edge, self.class.values([source]))
        found unless found.empty?
      end
    end

    #: (AssociationActivityEdge, Array[untyped]) -> Array[untyped]
    def read(edge, values)
      values.each_slice(Support::IDS_PER_STATEMENT).flat_map do |slice|
        edge.relation(slice).pluck(edge.column)
      end.compact.uniq
    end

    # Sources are only ever a Query or a plain Array, so the one mutation
    # left, `instance_of?` for `is_a?`, cannot change an answer.
    # mutant:disable
    #: (source, Symbol?) -> Query?
    def subquery(source, type)
      source if source.is_a?(Query) && source.type == type
    end
  end
end
