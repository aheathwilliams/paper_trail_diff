# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Loads the `belongs_to` targets owners pointed at during one activity range:
  # at its start and after each change inside it.
  #
  # PT-AT records a version's foreign keys as they stood after its change, so
  # the target at the start comes from the latest version before it, and the
  # version a range ends at names a target only after the range. Reading only
  # the owners' versions inside the range misses a target whose owner did not
  # change there -- an author renamed under an article nobody edited.
  class ActivityTargetCandidateLoader
    # A plain class rather than Data.define, which arrived in Ruby 3.2 while this
    # gem supports 3.1.
    class Row
      attr_reader :owner_id #: untyped
      attr_reader :foreign_key_id #: untyped
      attr_reader :foreign_type #: String?
      attr_reader :created_at #: untyped
      attr_reader :event #: String?
      attr_reader :version_id #: untyped

      #: (untyped, untyped, String?, ?untyped, ?String?, ?untyped) -> void
      def initialize(owner_id, foreign_key_id, foreign_type, created_at = nil, event = nil, # rubocop:disable Metrics/ParameterLists
                     version_id = nil)
        @owner_id = owner_id
        @foreign_key_id = foreign_key_id
        @foreign_type = foreign_type
        @created_at = created_at
        @event = event
        @version_id = version_id
        freeze
      end
    end

    #: (untyped, Array[untyped], untyped, ActivityRange) -> void
    def initialize(owner_class, owner_ids, reflection, range)
      @owner_class = owner_class
      @owner_ids = owner_ids
      @reflection = reflection
      @range = range
    end

    #: () -> Array[Row]
    def call
      rows = historical_rows.select do |row|
        @range.recorded_before_end?(row.created_at, row.version_id)
      end
      @range.current_end? ? rows + current_rows : rows
    end

    # One shared query keeps the owner and timestamp needed to partition a
    # batch's candidates back into each root's exact activity range.
    #: () -> Array[Row]
    def historical_rows
      return [] if composite_foreign_key?

      version_class = @owner_class.paper_trail.version_class
      relation = candidate_scope(version_class).call(historical_relation(version_class))
      historical_columns(relation, version_class).map do |row|
        owner_id, id, type, created_at, event, version_id = row
        Row.new(Support.record_id(@owner_class, owner_id), id, type, created_at, event, version_id)
      end
    end

    # The live row holds the state at a range that ends at the current record.
    #: () -> Array[Row]
    def current_rows
      return [] if composite_foreign_key? || @owner_class.composite_primary_key?

      live_rows.filter_map do |owner_id, id, type|
        Row.new(owner_id, id, type) unless id.nil?
      end
    end

    private

    # @rbs @owner_class: untyped
    # @rbs @owner_ids: Array[untyped]
    # @rbs @reflection: untyped
    # @rbs @range: ActivityRange

    #: (untyped) -> untyped
    def historical_relation(version_class)
      association_class.joins(:version)
                       .where(foreign_key_name: @reflection.foreign_key)
                       .where(version_class.table_name => {
                                item_type: @owner_class.base_class.name, item_id: @owner_ids
                              })
    end

    #: (untyped, untyped) -> Array[Array[untyped]]
    def historical_columns(relation, version_class)
      versions = version_class.arel_table
      associations = association_class.arel_table
      relation.pluck(versions[:item_id], associations[:foreign_key_id],
                     associations[:foreign_type], versions[:created_at], versions[:event],
                     versions[:id])
    end

    # A polymorphic key names its target in a type column; any other names it
    # in the reflection, so no type is read.
    #: () -> Array[Array[untyped]]
    def live_rows
      relation = @owner_class.unscoped.where(@owner_class.primary_key => @owner_ids)
      key = @reflection.foreign_key
      return relation.pluck(@owner_class.primary_key, key) unless @reflection.polymorphic?

      relation.pluck(@owner_class.primary_key, key, @reflection.foreign_type)
    end

    #: (untyped) -> VersionAssociationCandidateScope
    def candidate_scope(version_class)
      VersionAssociationCandidateScope.new(version_class, @range.start_time,
                                           end_at: @range.end_time)
    end

    #: () -> untyped
    def association_class
      @owner_class.paper_trail.version_association_class
    end

    #: () -> bool
    def composite_foreign_key?
      @reflection.foreign_key.is_a?(Array)
    end
  end
end
