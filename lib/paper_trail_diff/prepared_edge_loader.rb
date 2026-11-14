# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Loads every historical identity that can participate in one association edge.
  class PreparedEdgeLoader
    # A history shares `children` with its activity index, which reads the
    # children this finds again.
    #: (PreparedRecordIndex, children: PreparedChildCandidates) -> void
    def initialize(records, children:)
      @records = records
      @children = children
    end

    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def call(owner_class, owner_ids, reflection)
      return belongs_to_groups(owner_class, owner_ids, reflection) if reflection.belongs_to?

      child_groups(owner_class, owner_ids, reflection)
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @children: PreparedChildCandidates

    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def belongs_to_groups(owner_class, owner_ids, reflection)
      key = reflection.foreign_key
      return polymorphic_groups(owner_class, owner_ids, reflection, key) if reflection.polymorphic?

      group_for(reflection.klass, @records.attribute_values_for(owner_class, owner_ids, key))
    end

    # Grouping only decides what to preload, so a type that names no class is
    # left to raise where that state is read.
    #: (untyped, Array[untyped], untyped, String) -> Hash[String, Hash[Symbol, untyped]]
    def polymorphic_groups(owner_class, owner_ids, reflection, key)
      grouped = {} #: Hash[String, Hash[Symbol, untyped]]
      @records.records_for(owner_class, owner_ids).each do |owner|
        id = owner.public_send(key)
        type = owner.public_send(reflection.foreign_type).to_s
        model_class = AssociationTraversal.named_class(type)
        add_identity(grouped, model_class, id) if model_class && id
      end
      grouped.transform_values { |group| group.merge(ids: group.fetch(:ids).uniq) }
    end

    # Each owner's children, recorded or live, each once.
    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def child_groups(owner_class, owner_ids, reflection)
      historical, live = @children.call(owner_class, owner_ids, reflection)
      empty = [] #: Array[untyped]
      owners = owner_ids.to_h do |id|
        key = id.to_s
        [key, historical.fetch(key, empty).map { |row| row.fetch(1) } | live.fetch(key, empty)]
      end
      group_for(reflection.klass, owners.values.flatten, owners: owners)
    end

    #: (Hash[String, Hash[Symbol, untyped]], untyped, untyped) -> void
    def add_identity(groups, model_class, id)
      group = groups[model_class.name.to_s] ||= { model: model_class, ids: [] }
      group.fetch(:ids) << id
    end

    #: (untyped, Array[untyped], ?owners: Hash[String, Array[untyped]]?) -> Hash[String, Hash[Symbol, untyped]]
    def group_for(model_class, ids, owners: nil)
      unique = ids.compact.uniq
      return {} if unique.empty?

      group = { model: model_class, ids: unique } #: Hash[Symbol, untyped]
      group[:owners] = owners if owners
      { model_class.name => group }
    end
  end
end
