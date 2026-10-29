# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reads plain direct edges without creating AR records for their members.
  class PreparedStateAssociationReader
    #: (PreparedRecordIndex, untyped) -> void
    def initialize(records, edges)
      @records = records
      @edges = edges
    end

    #: (PreparedRecordState, untyped, untyped) -> [bool, Array[PreparedRecordState]]
    def call(owner, reflection, boundary)
      return [false, []] unless supported?(reflection)

      if reflection.belongs_to?
        id = owner.attributes[reflection.foreign_key.to_s]
        return [true, []] if id.nil?

        handled, state = @records.snapshot_state_before(reflection.klass, id, boundary)
        return [handled, state ? [state] : []]
      end
      children(owner, reflection, boundary)
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @edges: untyped

    #: (untyped) -> bool
    def supported?(reflection)
      !reflection.options[:through] && !reflection.polymorphic? && reflection.scope.nil? &&
        !reflection.klass.default_scopes? && !reflection.foreign_key.is_a?(Array) &&
        %i[belongs_to has_one has_many].include?(reflection.macro)
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
