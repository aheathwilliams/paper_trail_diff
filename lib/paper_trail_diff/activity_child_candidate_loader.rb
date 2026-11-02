# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Loads direct-child identities active at or after one activity boundary. A
  # composite foreign key reads none, as loaded history cannot index it.
  class ActivityChildCandidateLoader
    #: (untyped, Array[untyped], untyped, untyped) -> void
    def initialize(parent_class, parent_ids, reflection, start_at)
      @parent_class = parent_class
      @parent_ids = parent_ids
      @reflection = reflection
      @start_at = start_at
      @foreign_key = AssociationKey.scalar_foreign_key(reflection)
    end

    # One shared query retains the owner and timestamp needed to partition a
    # batch's candidates back into each root's exact activity range.
    #: () -> Array[Array[untyped]]
    def historical_rows
      foreign_key = @foreign_key
      return [] unless foreign_key

      version_class = @parent_class.paper_trail.version_class
      scope = VersionAssociationCandidateScope.new(version_class, @start_at)
      typed_rows(pluck_rows(scope.call(historical_relation(version_class, foreign_key)),
                            version_class))
    end

    #: () -> Array[Array[untyped]]
    def current_pairs
      foreign_key = @foreign_key
      return [] unless foreign_key

      relation = @reflection.klass.base_class.unscoped.where(foreign_key => @parent_ids)
      relation = relation.where(@reflection.type => parent_types) if @reflection.type
      relation.pluck(foreign_key, @reflection.klass.primary_key)
    end

    private

    # @rbs @parent_class: untyped
    # @rbs @parent_ids: Array[untyped]
    # @rbs @reflection: untyped
    # @rbs @start_at: untyped
    # @rbs @foreign_key: String?

    #: (Array[Array[untyped]]) -> Array[Array[untyped]]
    def typed_rows(rows)
      rows.map do |owner_id, item_id, created_at, event|
        [owner_id, Support.record_id(@reflection.klass, item_id), created_at, event]
      end
    end

    #: (untyped, String) -> untyped
    def historical_relation(version_class, foreign_key)
      associations = @parent_class.paper_trail.version_association_class
      VersionTable.joined(associations, version_class).where(
        foreign_key_name: foreign_key,
        foreign_key_id: @parent_ids,
        foreign_type: parent_types
      ).where(version_class.table_name => { item_type: @reflection.klass.base_class.name })
    end

    #: (untyped, untyped) -> Array[Array[untyped]]
    def pluck_rows(relation, version_class)
      versions = version_class.arel_table
      associations = @parent_class.paper_trail.version_association_class.arel_table
      relation.pluck(associations[:foreign_key_id], versions[:item_id], versions[:created_at],
                     versions[:event])
    end

    #: () -> Array[String?]
    def parent_types
      [nil, '', @parent_class.name, @parent_class.base_class.name]
    end
  end
end
