# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reads plain edges without creating AR records for their members: direct
  # edges, polymorphic `belongs_to`, and `has_many :through` built from them.
  class PreparedStateAssociationReader
    #: (PreparedRecordIndex, untyped, ScopeCondition::Cache) -> void
    def initialize(records, edges, conditions)
      @records = records
      @edges = edges
      @conditions = conditions
    end

    # Unranked, as a part of a has_many through is read, it returns every row
    # the part's conditions admit, a record reached twice appearing twice.
    #: (PreparedRecordState, untyped, untyped, ?ranked: bool) -> [bool, Array[PreparedRecordState]]
    def call(owner, reflection, boundary, ranked: true)
      return [false, []] unless supported?(reflection, ranked)
      return through(owner, reflection, boundary, ranked) if reflection.options[:through]
      return target(owner, reflection, boundary, ranked) if reflection.belongs_to?

      children(owner, reflection, boundary, ranked)
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @edges: untyped
    # @rbs @conditions: ScopeCondition::Cache

    # A polymorphic target's class is known only once a record names it, so
    # `target` reads its scope for each record instead.
    #: (untyped, bool) -> bool
    def supported?(reflection, ranked)
      reflection.polymorphic? || !@conditions.call(reflection, ranked: ranked).nil?
    end

    #: (PreparedRecordState, untyped, bool, ?untyped) -> bool
    def in_scope?(state, reflection, ranked, model_class = reflection.klass)
      condition = @conditions.call(reflection, model_class, ranked: ranked) #: ScopeCondition
      condition.matches?(state.attributes)
    end

    # A type that names no class, or a class whose scope cannot be read as
    # conditions, is left to the record path, which raises for the first and
    # reads the second through its association.
    #: (PreparedRecordState, untyped, untyped, bool) -> [bool, Array[PreparedRecordState]]
    def target(owner, reflection, boundary, ranked)
      id = owner.attributes[reflection.foreign_key.to_s]
      return [true, []] if id.nil?

      type = owner.attributes[reflection.foreign_type]
      model_class = AssociationTraversal.stored_target(reflection, type)
      return [false, []] unless model_class &&
                                @conditions.call(reflection, model_class, ranked: ranked)

      handled, state = @records.snapshot_state_before(model_class, id, boundary)
      [handled, state && target?(state, reflection, ranked, model_class) ? [state] : []]
    end

    # A target class that is an STI subclass reads no sibling's row, as Active
    # Record's type condition reads none.
    #: (PreparedRecordState, untyped, bool, untyped) -> bool
    def target?(state, reflection, ranked, model_class)
      AssociationTraversal.sti_member?(model_class, state.attributes) &&
        in_scope?(state, reflection, ranked, model_class)
    end

    # The members of each join record the owner had at the boundary, as
    # PreparedHistory#through_records reads them from records. Under
    # `source_type:`, only join records of that type count. A through reads
    # its parts unranked, as its one query joins every row of each.
    #: (PreparedRecordState, untyped, untyped, bool) -> [bool, Array[PreparedRecordState]]
    def through(owner, reflection, boundary, ranked)
      handled, joins = call(owner, reflection.through_reflection, boundary, ranked: false)
      return [false, []] unless handled

      rows = [] #: Array[PreparedRecordState]
      ScopeCondition.in_key_order(joins, &:model_class).each do |join|
        next unless typed_join?(reflection, join)

        handled, states = call(join, reflection.source_reflection, boundary, ranked: false)
        return [false, []] unless handled

        rows.concat(states)
      end
      [true, through_members(reflection, rows, ranked)]
    end

    # The through's own scope applies after its parts' scopes, to each row,
    # and a ranked read then keeps a record reached twice as one member.
    #: (untyped, Array[PreparedRecordState], bool) -> Array[PreparedRecordState]
    def through_members(reflection, rows, ranked)
      condition = @conditions.call(reflection, ranked: ranked) #: ScopeCondition
      members = condition.members(rows)
      return members unless ranked

      first_if_one(reflection, condition, members.uniq { |state| identity(state) })
    end

    # A has_one keeps one of its records (see ScopeCondition#first).
    #: (untyped, ScopeCondition, Array[PreparedRecordState]) -> Array[PreparedRecordState]
    def first_if_one(reflection, condition, states)
      return states if reflection.collection?

      condition.first(states, in_order: reflection.through_reflection?)
    end

    #: (untyped, PreparedRecordState) -> bool
    def typed_join?(reflection, join)
      AssociationTraversal.source_type_member?(reflection, join.attributes[reflection.foreign_type])
    end

    # A record reached through two join records is one member.
    #: (PreparedRecordState) -> Array[untyped]
    def identity(state)
      model = state.model_class
      [model.base_class.name, *Array(model.primary_key).map { |key| state.attributes[key].to_s }]
    end

    # The scope's condition and the owner's id are read once for all the
    # owner's children, which are read at every boundary.
    #: (PreparedRecordState, untyped, untyped, bool) -> [bool, Array[PreparedRecordState]]
    def children(owner, reflection, boundary, ranked)
      condition = @conditions.call(reflection, ranked: ranked) #: ScopeCondition
      owner_id = owner_id(owner)
      selected = [] #: Array[PreparedRecordState]
      @edges.call(owner.model_class, reflection).each_value do |group|
        ids_for(group, owner_id).each do |id|
          handled, child = @records.snapshot_state_before(group.fetch(:model), id, boundary)
          return [false, []] unless handled

          selected << child if child && member?(child, owner_id, reflection, condition)
        end
      end
      return [true, selected] unless ranked

      [true, first_if_one(reflection, condition, condition.rank(selected))]
    end

    #: (untyped, String) -> Array[untyped]
    def ids_for(group, owner_id)
      owners = group[:owners]
      empty = [] #: Array[untyped]
      owners ? owners.fetch(owner_id, empty) : group.fetch(:ids)
    end

    #: (PreparedRecordState, String, untyped, ScopeCondition) -> bool
    def member?(child, owner_id, reflection, condition)
      attributes = child.attributes
      attributes[reflection.foreign_key.to_s].to_s == owner_id &&
        AssociationTraversal.sti_member?(reflection.klass, attributes) &&
        condition.matches?(attributes) && owner_typed?(attributes, reflection)
    end

    # An `as:` child names its owner by type as well.
    #: (Hash[String, untyped], untyped) -> bool
    def owner_typed?(attributes, reflection)
      !reflection.options[:as] ||
        AssociationTraversal.owner_type(reflection) == attributes[reflection.type.to_s].to_s
    end

    #: (PreparedRecordState) -> String
    def owner_id(owner)
      owner.attributes[owner.model_class.primary_key].to_s
    end
  end
end
