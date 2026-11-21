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

    # The rows of `model` among `rows` that no version was ever saved for. A
    # database compares the key with item_id only when they share a type;
    # otherwise the keys of the rows that have versions are read as values,
    # which a database casts back to the key's type.
    #: (untyped, untyped) -> untyped
    def without_versions(model, rows)
      return rows.where(versions_of(model).arel.exists.not) if item_key?(model)

      key = model.primary_key
      versioned = VersionQuery.for_items(model, rows.pluck(key)).distinct.pluck(:item_id)
      saved = { key => versioned } #: Hash[untyped, untyped]
      rows.where.not(saved)
    end

    #: (untyped) -> bool
    def item_key?(model)
      versions = model.paper_trail.version_class
      column_type(versions, 'item_id') == column_type(model, model.primary_key)
    end

    # The versions of the row a statement over the model's table is at.
    #: (untyped) -> untyped
    def versions_of(model)
      item_id = model.paper_trail.version_class.arel_table[:item_id]
      VersionQuery.for_model(model).where(item_id.eq(model.arel_table[model.primary_key]))
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
        @column = @target.arel_table[reflection.foreign_key]
        @type = column_type(@target, reflection.foreign_key)
        @filter_type = column_type(@target, @target.primary_key)
      end

      #: (untyped) -> untyped
      def relation(filter)
        asked = { @target.primary_key => filter } #: Hash[untyped, untyped]
        rows = @target.unscoped.where(asked)
        type = @reflection.type
        held = { type => @owner.polymorphic_name } #: Hash[untyped, untyped]
        rows = rows.where(held) if type
        without_versions(@target, rows)
      end

      # @rbs @target: untyped
    end

    # The owners no version was ever saved for that point at a target, such
    # as line items from before PaperTrail that name a product: such an owner
    # has held its live key throughout, as an analysis reads it, so a change
    # to the target, or below it, is a change the owner holds. PT-AT records
    # a belongs_to on the owner's own versions, and an owner without any is
    # in none of its rows.
    class UnversionedOwner < AssociationActivityEdge
      # Such an owner holds its key through any window, so none is kept.
      #: (untyped, TimeRange?, ?foreign_type: String?) -> void
      def initialize(reflection, _time_range, foreign_type: nil)
        super(reflection, nil)
        @foreign_type = foreign_type
        key = @owner.primary_key
        @column = @owner.arel_table[key]
        @type = column_type(@owner, key)
        @filter_type = column_type(@owner, reflection.foreign_key)
      end

      # The types the owners' polymorphic keys name now. One only owners with
      # versions name costs a lookup that finds nothing.
      #: () -> Array[String]
      def target_types
        @owner.unscoped.distinct.pluck(@reflection.foreign_type).reject(&:blank?)
      end

      #: (untyped) -> untyped
      def relation(filter)
        held = { @reflection.foreign_key => filter } #: Hash[untyped, untyped]
        held[@reflection.foreign_type] = @foreign_type if @foreign_type
        without_versions(@owner, @owner.unscoped.where(held))
      end

      # @rbs @foreign_type: String?
    end

    # The owners of children whose first version since the window opened did
    # not create them, such as rows from before PaperTrail that the window
    # moves or detaches. PT-AT stores the keys a version saved, so the owner
    # such a child held until that version is in no row, only in the
    # version's stored state, as ActivityChildCandidateLoader reads it. One
    # saved after the window's end holds the owner the child had there too.
    class FirstVersion < AssociationActivityEdge
      #: (untyped, TimeRange?) -> void
      def initialize(reflection, time_range)
        super
        @target = reflection.klass
        @filter_type = column_type(@target.paper_trail.version_class, 'item_id')
      end

      # A create stores no state, so the first versions read are those that
      # did not create their child.
      #: (untyped) -> untyped
      def relation(filter)
        relation = VersionQuery.for_model(@target).where(item_id: filter).where.not(object: nil)
        versions = relation.arel_table
        relation = relation.where(VersionQuery.no_earlier_version(versions))
        start = @time_range&.begin_time
        start ? relation.where(versions[:created_at].gteq(start)) : relation
      end

      # The owners the first versions of the children `filter` selects name in
      # their stored states. An `as:` child's type must name one of the
      # owner's types, which take a child with no type, as any plain child has.
      # A version with no state for the key names no owner.
      #: (untyped) -> Array[untyped]
      def owners(filter)
        types = RecordedOwner.types(@reflection, @owner)
        relation(filter).select(:object).filter_map do |version|
          state = version.object_deserialized
          state[@reflection.foreign_key] if types.include?(state[@reflection.type])
        end
      end

      # The same for children's ids read as values, in slices.
      #: (Array[untyped]) -> Array[untyped]
      def owners_of(ids)
        ids.each_slice(Support::IDS_PER_STATEMENT).flat_map { |slice| owners(slice) }
      end

      # @rbs @target: untyped
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
