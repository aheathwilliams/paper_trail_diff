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

    #: (PreparedRecordState, untyped, untyped) -> [bool, Array[PreparedRecordState]]
    def call(owner, reflection, boundary)
      return [false, []] unless supported?(reflection)
      return through(owner, reflection, boundary) if reflection.options[:through]
      return target(owner, reflection, boundary) if reflection.belongs_to?

      children(owner, reflection, boundary)
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @edges: untyped
    # @rbs @conditions: ScopeCondition::Cache

    # A polymorphic target's class is known only once a record names it, so
    # `target` reads its scope for each record instead.
    #: (untyped) -> bool
    def supported?(reflection)
      !reflection.foreign_key.is_a?(Array) &&
        %i[belongs_to has_one has_many].include?(reflection.macro) &&
        (reflection.polymorphic? || !@conditions.call(reflection).nil?)
    end

    #: (PreparedRecordState, untyped, ?untyped) -> bool
    def in_scope?(state, reflection, model_class = reflection.klass)
      condition = @conditions.call(reflection, model_class) #: ScopeCondition
      condition.matches?(state.attributes)
    end

    # A type that names no class, or a class whose scope cannot be read as
    # conditions, is left to the record path, which raises for the first and
    # reads the second through its association.
    #: (PreparedRecordState, untyped, untyped) -> [bool, Array[PreparedRecordState]]
    def target(owner, reflection, boundary)
      id = owner.attributes[reflection.foreign_key.to_s]
      return [true, []] if id.nil?

      model_class = target_class(owner, reflection)
      return [false, []] unless model_class && @conditions.call(reflection, model_class)

      handled, state = @records.snapshot_state_before(model_class, id, boundary)
      [handled, state && in_scope?(state, reflection, model_class) ? [state] : []]
    end

    #: (PreparedRecordState, untyped) -> untyped
    def target_class(owner, reflection)
      return reflection.klass unless reflection.polymorphic?

      AssociationTraversal.named_class(owner.attributes[reflection.foreign_type].to_s)
    end

    # The members of each join record the owner had at the boundary, as
    # PreparedHistory#through_records reads them from records. Under
    # `source_type:`, only join records of that type count.
    #: (PreparedRecordState, untyped, untyped) -> [bool, Array[PreparedRecordState]]
    def through(owner, reflection, boundary)
      handled, joins = call(owner, reflection.through_reflection, boundary)
      return [false, []] unless handled

      members = [] #: Array[PreparedRecordState]
      joins.each do |join|
        next unless typed_join?(reflection, join)

        handled, states = call(join, reflection.source_reflection, boundary)
        return [false, []] unless handled

        members.concat(states)
      end
      members = members.uniq { |state| identity(state) }.select { |state| in_scope?(state, reflection) }
      [true, reflection.collection? ? members : members.first(1)]
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

    #: (PreparedRecordState, untyped, untyped) -> [bool, Array[PreparedRecordState]]
    def children(owner, reflection, boundary)
      selected = [] #: Array[PreparedRecordState]
      @edges.call(owner.model_class, reflection).each_value do |group|
        ids_for(group, owner).each do |id|
          handled, child = @records.snapshot_state_before(group.fetch(:model), id, boundary)
          return [false, []] unless handled

          selected << child if child && member?(child, owner, reflection)
        end
      end
      [true, reflection.collection? ? selected : selected.first(1)]
    end

    #: (untyped, PreparedRecordState) -> Array[untyped]
    def ids_for(group, owner)
      owners = group[:owners]
      empty = [] #: Array[untyped]
      owners ? owners.fetch(owner_id(owner), empty) : group.fetch(:ids)
    end

    #: (PreparedRecordState, PreparedRecordState, untyped) -> bool
    def member?(child, owner, reflection)
      return false unless child.attributes[reflection.foreign_key.to_s].to_s == owner_id(owner)
      return false unless AssociationTraversal.sti_member?(reflection.klass, child.attributes)
      return false unless in_scope?(child, reflection)
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
