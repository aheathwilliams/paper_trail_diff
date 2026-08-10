# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Loads direct-child identities active at or after one activity boundary.
  class ActivityChildCandidateLoader
    #: (untyped, Array[untyped], untyped, ActivityRange) -> void
    def initialize(parent_class, parent_ids, reflection, range)
      @parent_class = parent_class
      @parent_ids = parent_ids
      @reflection = reflection
      @range = range
    end

    #: () -> Array[untyped]
    def call
      historical_ids | current_ids
    end

    private

    # @rbs @parent_class: untyped
    # @rbs @parent_ids: Array[untyped]
    # @rbs @reflection: untyped
    # @rbs @range: ActivityRange

    #: () -> Array[untyped]
    def historical_ids
      version_class = @parent_class.paper_trail.version_class
      candidate_scope(version_class).call(historical_relation(version_class))
                                    .distinct.pluck(version_class.arel_table[:item_id])
    end

    #: (untyped) -> untyped
    def historical_relation(version_class)
      @parent_class.paper_trail.version_association_class.joins(:version).where(
        foreign_key_name: @reflection.foreign_key.to_s,
        foreign_key_id: @parent_ids,
        foreign_type: parent_types
      ).where(version_class.table_name => { item_type: child_item_type })
    end

    #: (untyped) -> VersionAssociationCandidateScope
    def candidate_scope(version_class)
      VersionAssociationCandidateScope.new(
        version_class,
        @range.start_time,
        end_at: @range.end_time
      )
    end

    #: () -> Array[untyped]
    def current_ids
      return [] unless @range.current_end?

      relation = @reflection.klass.base_class.unscoped.where(
        @reflection.foreign_key => @parent_ids
      )
      relation = relation.where(@reflection.type => parent_types) if @reflection.options[:as]
      relation.distinct.pluck(@reflection.klass.primary_key)
    end

    #: () -> String
    def child_item_type
      @reflection.klass.base_class.name
    end

    #: () -> Array[String?]
    def parent_types
      [nil, '', @parent_class.name.to_s, @parent_class.base_class.name.to_s].uniq
    end
  end
end
