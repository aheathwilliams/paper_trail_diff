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
      !reflection.foreign_key.is_a?(Array) &&
        %i[belongs_to has_one has_many].include?(reflection.macro) &&
        (reflection.polymorphic? || !@conditions.call(reflection, ranked: ranked).nil?)
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

      model_class = target_class(owner, reflection)
      return [false, []] unless model_class &&
                                @conditions.call(reflection, model_class, ranked: ranked)

      handled, state = @records.snapshot_state_before(model_class, id, boundary)
      [handled, state && in_scope?(state, reflection, ranked, model_class) ? [state] : []]
    end

    #: (PreparedRecordState, untyped) -> untyped
    def target_class(owner, reflection)
      return reflection.klass unless reflection.polymorphic?

      AssociationTraversal.named_class(owner.attributes[reflection.foreign_type].to_s)
    end

    # The members of each join record the owner had at the boundary, as
    # PreparedHistory#through_records reads them from records. Under
    # `source_type:`, only join records of that type count. A has_many
    # through reads its parts unranked, as its query does.
    #: (PreparedRecordState, untyped, untyped, bool) -> [bool, Array[PreparedRecordState]]
    def through(owner, reflection, boundary, ranked)
      parts_ranked = ranked && !reflection.collection?
      handled, joins = call(owner, reflection.through_reflection, boundary, ranked: parts_ranked)
      return [false, []] unless handled

      rows = [] #: Array[PreparedRecordState]
      joins.each do |join|
        next unless typed_join?(reflection, join)

        handled, states = call(join, reflection.source_reflection, boundary, ranked: parts_ranked)
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

      first_if_one(reflection, members.uniq { |state| identity(state) })
    end

    # A has_one keeps the first of its records.
    #: (untyped, Array[PreparedRecordState]) -> Array[PreparedRecordState]
    def first_if_one(reflection, states)
      reflection.collection? ? states : states.first(1)
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

    #: (PreparedRecordState, untyped, untyped, bool) -> [bool, Array[PreparedRecordState]]
    def children(owner, reflection, boundary, ranked)
      selected = [] #: Array[PreparedRecordState]
      @edges.call(owner.model_class, reflection).each_value do |group|
        ids_for(group, owner).each do |id|
          handled, child = @records.snapshot_state_before(group.fetch(:model), id, boundary)
          return [false, []] unless handled

          selected << child if child && member?(child, owner, reflection, ranked)
        end
      end
      return [true, selected] unless ranked

      condition = @conditions.call(reflection) #: ScopeCondition
      [true, first_if_one(reflection, condition.rank(selected))]
    end

    #: (untyped, PreparedRecordState) -> Array[untyped]
    def ids_for(group, owner)
      owners = group[:owners]
      empty = [] #: Array[untyped]
      owners ? owners.fetch(owner_id(owner), empty) : group.fetch(:ids)
    end

    #: (PreparedRecordState, PreparedRecordState, untyped, bool) -> bool
    def member?(child, owner, reflection, ranked)
      return false unless child.attributes[reflection.foreign_key.to_s].to_s == owner_id(owner)
      return false unless AssociationTraversal.sti_member?(reflection.klass, child.attributes)
      return false unless in_scope?(child, reflection, ranked)
      return true unless reflection.options[:as]

      matching_type?(child, owner.model_class, reflection)
    end

    #: (PreparedRecordState) -> String
    def owner_id(owner)
      owner.attributes[owner.model_class.primary_key].to_s
    end

    #: (PreparedRecordState, untyped, untyped) -> bool
    def matching_type?(child, model, reflection)
      types = [model.name, model.base_class.name,
               reflection.active_record.name]
      types.include?(child.attributes[reflection.type.to_s].to_s)
    end
  end
end
