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
      model.columns_hash[name]&.type
    end

    #: (untyped) -> untyped
    def arel_value(filter)
      filter.is_a?(Array) ? filter : filter.arel
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
        relation = @associations.joins(:version)
                                .where(foreign_key_name: @reflection.foreign_key.to_s,
                                       foreign_type: owner_types)
                                .where(@versions.table_name => versions)
        candidates(@versions, relation)
      end

      private

      # @rbs @versions: untyped
      # @rbs @associations: untyped

      #: () -> Array[String?]
      def owner_types
        [nil, '', @owner.name.to_s, @owner.base_class.name.to_s].uniq
      end
    end

    # The owners that pointed at a target when the window opened or after a
    # change inside it, as PT-AT recorded them on the owners' versions.
    class BelongsTo < AssociationActivityEdge
      #: (untyped, TimeRange?, ?foreign_types: Array[String]?) -> void
      def initialize(reflection, time_range, foreign_types: nil)
        super(reflection, time_range)
        @foreign_types = foreign_types
        @versions = @owner.paper_trail.version_class
        @associations = @owner.paper_trail.version_association_class
        @column = @versions.arel_table[:item_id]
        @type = column_type(@versions, 'item_id')
        @filter_type = column_type(@associations, 'foreign_key_id')
      end

      # The types a polymorphic key's rows name, the only way to know its targets.
      #: () -> Array[String]
      def target_types
        candidates(@versions, owner_rows(foreign_key_name: @reflection.foreign_key.to_s))
          .distinct.pluck(@associations.arel_table[:foreign_type]).compact
      end

      #: (untyped) -> untyped
      def relation(filter)
        conditions = { foreign_key_name: @reflection.foreign_key.to_s, foreign_key_id: filter }
        conditions[:foreign_type] = @foreign_types if @foreign_types
        candidates(@versions, owner_rows(conditions))
      end

      private

      # @rbs @foreign_types: Array[String]?
      # @rbs @versions: untyped
      # @rbs @associations: untyped

      #: (Hash[Symbol, untyped]) -> untyped
      def owner_rows(conditions)
        @associations.joins(:version).where(conditions)
                     .where(@versions.table_name => { item_type: @owner.base_class.name })
      end
    end

    # The owners a HABTM join row links to a target now. A join table has no
    # model to type its columns, so the owner column is read by quoted name.
    class LiveHabtm < AssociationActivityEdge
      #: (untyped, TimeRange?) -> void
      def initialize(reflection, time_range)
        super
        @table = arel.const_get(:Table).new(reflection.join_table)
        columns = join_columns
        @type = columns[reflection.foreign_key.to_s]
        @filter_type = columns[reflection.association_foreign_key.to_s]
        @column = quoted_owner_column
      end

      #: () -> bool
      def available?
        true
      end

      #: (untyped) -> untyped
      def relation(filter)
        target = @table[@reflection.association_foreign_key.to_s]
        @owner.base_class.unscoped.from(@table).where(target.in(arel_value(filter)))
      end

      private

      # @rbs @table: untyped

      #: () -> Hash[String, Symbol?]
      def join_columns
        connected do |connection|
          connection.columns(@reflection.join_table.to_s).to_h do |column|
            [column.name, column.type]
          end
        end
      end

      #: () -> untyped
      def quoted_owner_column
        connected do |connection|
          arel.sql("#{connection.quote_table_name(@reflection.join_table.to_s)}." \
                   "#{connection.quote_column_name(@reflection.foreign_key.to_s)}")
        end
      end

      # Arel ships no signatures; see VersionQuery.
      #: () -> untyped
      def arel
        Object.const_get(:Arel)
      end

      # Active Record 7.1 has no `with_connection`; see VersionAssociationCandidateScope.
      #: [T] () { (untyped) -> T } -> T
      def connected(&block)
        return @owner.with_connection(&block) if @owner.respond_to?(:with_connection)

        yield(@owner.connection)
      end
    end

    # The owners whose versions PT-AT recorded a HABTM target with, keyed by
    # the transaction each version was saved in.
    class RecordedHabtm < AssociationActivityEdge
      #: (untyped, TimeRange?) -> void
      def initialize(reflection, time_range)
        super
        @versions = @owner.paper_trail.version_class
        @associations = @owner.paper_trail.version_association_class
        @column = @versions.arel_table[:item_id]
        @type = column_type(@versions, 'item_id')
        @filter_type = column_type(@associations, 'foreign_key_id')
      end

      #: () -> bool
      def available?
        @versions.column_names.include?('transaction_id')
      end

      #: (untyped) -> untyped
      def relation(filter)
        transactions = @associations.where(foreign_key_name: @reflection.name.to_s,
                                           foreign_key_id: filter).select(:version_id)
        relation = @versions.where(item_type: @owner.base_class.name, transaction_id: transactions)
        range = @time_range
        range ? relation.where(created_at: range.begin_time..) : relation
      end

      # @rbs @versions: untyped
      # @rbs @associations: untyped
    end
  end
end
