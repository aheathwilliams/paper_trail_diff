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
    #: (PreparedRecordState, untyped, untyped, ?ranked: bool) -> Array[PreparedRecordState]
    def call(owner, reflection, boundary, ranked: true)
      return through(owner, reflection, boundary, ranked) if reflection.options[:through]
      return target(owner, reflection, boundary, ranked) if reflection.belongs_to?

      children(owner, reflection, boundary, ranked)
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @edges: untyped
    # @rbs @conditions: ScopeCondition::Cache

    #: (PreparedRecordState, untyped, bool, ?untyped) -> bool
    def in_scope?(state, reflection, ranked, model_class = reflection.klass)
      condition = @conditions.call(reflection, model_class, ranked: ranked) #: ScopeCondition
      condition.matches?(state.attributes)
    end

    #: (PreparedRecordState, untyped, untyped, bool) -> Array[PreparedRecordState]
    def target(owner, reflection, boundary, ranked)
      id = owner.attributes[reflection.foreign_key.to_s]
      return [] if id.nil?

      type = owner.attributes[reflection.foreign_type]
      model_class = AssociationTraversal.stored_target(reflection, type)
      unless model_class && @conditions.call(reflection, model_class, ranked: ranked) &&
             @records.loaded?(model_class, id)
        unreadable!(owner, reflection, type, model_class)
      end

      state = @records.snapshot_state_before(model_class, id, boundary)
      state && target?(state, reflection, ranked, model_class) ? [state] : []
    end

    # A polymorphic target's class is known only from the owner's type
    # column, so TraversalPreparer cannot check it up front: the type may name
    # no class, or one with no versions or a default scope history cannot read.
    #: (PreparedRecordState, untyped, untyped, untyped) -> bot
    def unreadable!(owner, reflection, type, model_class)
      owner_class = owner.model_class
      id = owner_id(owner)
      if model_class.nil? && !type.to_s.empty?
        AssociationTraversal.unnamed_target!(reflection, owner_class, id, type)
      end
      name = "#{owner_class.name}##{reflection.name}"
      unversioned!(name, model_class) unless model_class.nil? || Support.versioned?(model_class)

      raise UnsupportedAssociationError,
            "association #{name} cannot be read from history for #{owner_class.name} " \
            "#{id}: who was in it at a past point cannot be told"
    end

    #: (String, untyped) -> bot
    def unversioned!(name, model_class)
      raise UnversionedAssociationError,
            "association #{name} cannot be compared historically: it points at " \
            "#{model_class.name}, which is not versioned. Add `has_paper_trail` to " \
            "#{model_class.name}, or mirror the fields you need onto a model that has it."
    end

    # A target class that is an STI subclass reads no sibling's row, as Active
    # Record's type condition reads none.
    #: (PreparedRecordState, untyped, bool, untyped) -> bool
    def target?(state, reflection, ranked, model_class)
      AssociationTraversal.sti_member?(model_class, state.attributes) &&
        in_scope?(state, reflection, ranked, model_class)
    end

    # The members of each join record the owner had at the boundary. Under
    # `source_type:`, only join records of that type count. A through reads
    # its parts unranked, as its one query joins every row of each.
    #: (PreparedRecordState, untyped, untyped, bool) -> Array[PreparedRecordState]
    def through(owner, reflection, boundary, ranked)
      joins = call(owner, reflection.through_reflection, boundary, ranked: false)
      rows = ScopeCondition.in_key_order(joins, &:model_class).flat_map do |join|
        next [] unless typed_join?(reflection, join)

        call(join, reflection.source_reflection, boundary, ranked: false)
      end
      through_members(reflection, rows, ranked)
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

      condition.first(states, in_order: AssociationTraversal.join_order?(reflection))
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
    #: (PreparedRecordState, untyped, untyped, bool) -> Array[PreparedRecordState]
    def children(owner, reflection, boundary, ranked)
      condition = @conditions.call(reflection, ranked: ranked) #: ScopeCondition
      owner_id = owner_id(owner)
      selected = [] #: Array[PreparedRecordState]
      @edges.call(owner.model_class, reflection).each_value do |group|
        ids_for(group, owner_id).each do |id|
          child = @records.snapshot_state_before(group.fetch(:model), id, boundary)
          selected << child if child && member?(child, owner_id, reflection, condition)
        end
      end
      return selected unless ranked

      first_if_one(reflection, condition, condition.rank(selected))
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
