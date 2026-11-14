# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # One association edge read backwards for a window: given the ids of records
  # on its far side, the query for the owners that held them while it was open.
  #
  # `filter_type` is the type of the column those ids are compared with, and
  # `type` that of the owner column the query selects, so a caller can keep a
  # subquery only where the database can compare the two.
  class AssociationActivityEdge
    attr_reader :column #: untyped
    attr_reader :type #: Symbol?
    attr_reader :filter_type #: Symbol?

    #: (untyped, TimeRange?) -> void
    def initialize(reflection, time_range)
      @reflection = reflection
      @time_range = time_range
      @owner = reflection.active_record
    end

    #: () -> bool
    def available?
      !@reflection.foreign_key.is_a?(Array)
    end

    #: (untyped) -> untyped
    def relation(_filter)
      raise NotImplementedError, "#{self.class} must build its relation"
    end

    private

    # @rbs @reflection: untyped
    # @rbs @time_range: TimeRange?
    # @rbs @owner: untyped

    # The window plus the state when it opened, which is what
    # VersionAssociationCandidateScope selects for an activity analysis.
    #: (untyped, untyped) -> untyped
    def candidates(versions, relation)
      range = @time_range
      return relation unless range

      VersionAssociationCandidateScope.new(versions, range.begin_time, end_at: range.end_time)
                                      .call(relation)
    end

    #: (untyped, String) -> Symbol?
    def column_type(model, name)
      model.type_for_attribute(name).type
    end

    # The owners a child pointed at when the window opened or after a change
    # inside it, as PT-AT recorded them on the child's own versions.
    class Child < AssociationActivityEdge
      #: (untyped, TimeRange?) -> void
      def initialize(reflection, time_range)
        super
        @versions = reflection.klass.paper_trail.version_class
        @associations = reflection.klass.paper_trail.version_association_class
        @column = @associations.arel_table[:foreign_key_id]
        @type = column_type(@associations, 'foreign_key_id')
        @filter_type = column_type(@versions, 'item_id')
      end

      #: (untyped) -> untyped
      def relation(filter)
        versions = { item_type: @reflection.klass.base_class.name, item_id: filter }
        relation = VersionTable.joined(@associations, @versions)
                               .where(foreign_key_name: @reflection.foreign_key,
                                      foreign_type: owner_types)
                               .where(@versions.table_name => versions)
        candidates(@versions, relation)
      end

      private

      # @rbs @versions: untyped
      # @rbs @associations: untyped

      #: () -> Array[String?]
      def owner_types
        RecordedOwner.types(@reflection, @owner)
      end
    end

    # The owners of children no version was ever saved for, such as rows from
    # before PaperTrail: such a child has held its live key throughout, as an
    # analysis reads it, and so leads to a change further down.
    class Unversioned < AssociationActivityEdge
      #: (untyped, TimeRange?) -> void
      def initialize(reflection, time_range)
        super
        @target = reflection.klass
        @versions = @target.paper_trail.version_class
        @key = @target.primary_key
        @column = @target.arel_table[reflection.foreign_key]
        @type = column_type(@target, reflection.foreign_key)
        @filter_type = column_type(@target, @key)
      end

      #: (untyped) -> untyped
      def relation(filter)
        rows = @target.unscoped.where(@key => filter)
        type = @reflection.type
        held = { type => @owner.polymorphic_name } #: Hash[untyped, untyped]
        rows = rows.where(held) if type
        comparable? ? rows.where(versioned.not) : rows.where.not(@key => versioned_ids(filter))
      end

      private

      # @rbs @target: untyped
      # @rbs @versions: untyped
      # @rbs @key: String

      # A database compares the key with item_id only when they share a type.
      #: () -> bool
      def comparable?
        column_type(@versions, 'item_id') == @filter_type
      end

      #: () -> untyped
      def versioned
        table = @versions.arel_table
        VersionQuery.for_model(@target).where(table[:item_id].eq(@target.arel_table[@key]))
                    .arel.exists
      end

      #: (untyped) -> Array[untyped]
      def versioned_ids(filter)
        ids = filter.respond_to?(:arel) ? filter.distinct.pluck(*filter.select_values) : filter
        key = @target.type_for_attribute(@key)
        VersionQuery.for_items(@target, ids).distinct.pluck(:item_id).map { |id| key.cast(id) }
      end
    end

    # The owners that pointed at a target when the window opened or after a
    # change inside it, as PT-AT recorded them on the owners' versions.
    class BelongsTo < AssociationActivityEdge
      #: (untyped, TimeRange?, ?foreign_type: String?) -> void
      def initialize(reflection, time_range, foreign_type: nil)
        super(reflection, time_range)
        @foreign_type = foreign_type
        @versions = @owner.paper_trail.version_class
        @associations = @owner.paper_trail.version_association_class
        @column = @versions.arel_table[:item_id]
        @type = column_type(@versions, 'item_id')
        @filter_type = column_type(@associations, 'foreign_key_id')
      end

      # The types a polymorphic key's rows name, the only way to know its targets.
      #: () -> Array[String]
      def target_types
        candidates(@versions, owner_rows(foreign_key_name: @reflection.foreign_key))
          .distinct.pluck(@associations.arel_table[:foreign_type]).compact
      end

      # The owners that pointed at a target of this edge's type when the window
      # opened or after a change inside it, whichever target that was.
      #: () -> untyped
      def typed_owners
        conditions = { foreign_key_name: @reflection.foreign_key, foreign_type: @foreign_type }
        candidates(@versions, owner_rows(conditions)).select(@column)
      end

      #: (untyped) -> untyped
      def relation(filter)
        conditions = { foreign_key_name: @reflection.foreign_key, foreign_key_id: filter }
        conditions[:foreign_type] = @foreign_type if @foreign_type
        candidates(@versions, owner_rows(conditions))
      end

      private

      # @rbs @foreign_type: String?
      # @rbs @versions: untyped
      # @rbs @associations: untyped

      #: (Hash[Symbol, untyped]) -> untyped
      def owner_rows(conditions)
        VersionTable.joined(@associations, @versions).where(conditions)
                    .where(@versions.table_name => { item_type: @owner.base_class.name })
      end
    end
  end
end
