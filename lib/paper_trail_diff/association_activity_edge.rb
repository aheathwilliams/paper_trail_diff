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

    # The owners whose first version since the window opened did not create
    # them, such as line items from before PaperTrail that name a product:
    # until that version, such an owner held the key its stored state holds,
    # though PT-AT has no row for it. PT-AT records the key a version saved,
    # so where the version kept the key, as any destroy does, its row names
    # the key held and is matched in SQL (`relation`). Where the version may
    # have changed the key, only the stored state names it (`stored_owners`).
    # One saved after the window's end held that key through it too.
    class FirstOwnerVersion < AssociationActivityEdge
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

      #: (untyped) -> untyped
      def relation(filter)
        conditions = { foreign_key_id: filter } #: Hash[Symbol, untyped]
        conditions[:foreign_type] = @foreign_type if @foreign_type
        kept_rows.where(conditions)
      end

      # The owners whose first version may have changed the key, and whose
      # stored state names one of the targets `ids` reads, under `type` for a
      # polymorphic key. The targets are read only when such a version exists.
      #: (String?) { () -> Array[untyped] } -> Array[untyped]
      def stored_owners(type = nil)
        states = stored_states
        return [] if states.empty?

        targets = yield.to_set(&:to_s)
        states.filter_map do |item_id, state|
          next unless targets.include?(state[@reflection.foreign_key].to_s)

          # A key that is not polymorphic has no type, which `state` lacks too.
          item_id if state[@reflection.foreign_type] == type
        end
      end

      # The types a polymorphic key's first versions held: PT-AT's rows for
      # those that kept the key, and the stored states of the others.
      #: () -> Array[String]
      def target_types
        kept = kept_rows.pluck(@associations.arel_table[:foreign_type])
        stored = stored_states.map { |_item_id, state| state[@reflection.foreign_type] }
        (kept + stored).reject(&:blank?).uniq
      end

      private

      # @rbs @foreign_type: String?
      # @rbs @versions: untyped
      # @rbs @associations: untyped
      # @rbs @stored_states: Array[[untyped, Hash[String, untyped]]]?

      # PT-AT's rows for the key on the first versions that kept it.
      #: () -> untyped
      def kept_rows
        table = @versions.arel_table
        VersionTable.joined(@associations, @versions)
                    .where(foreign_key_name: @reflection.foreign_key)
                    .where(@versions.table_name => { item_type: @owner.base_class.name })
                    .where(first_saved(table)).where(key_changes(table).not)
      end

      # A create stores no state and holds no earlier key, so the first
      # versions read are those that did not create their owner.
      #: (untyped) -> untyped
      def first_saved(table)
        first = table[:object].not_eq(nil).and(VersionQuery.no_earlier_version(table))
        start = @time_range&.begin_time
        start ? first.and(table[:created_at].gteq(start)) : first
      end

      # Item ids and stored states of the first versions that may have
      # changed the key.
      #: () -> Array[[untyped, Hash[String, untyped]]]
      def stored_states
        @stored_states ||= begin
          table = @versions.arel_table
          VersionQuery.for_model(@owner).where(first_saved(table)).where(key_changes(table))
                      .map { |version| [version.item_id, version.object_deserialized] }
        end
      end

      # The versions that may have changed the key: any but a destroy whose
      # recorded changes name it, or that records none. Without PaperTrail's
      # own recorded changes for the key, any but a destroy may have.
      #: (untyped) -> untyped
      def key_changes(table)
        saved = table[:event].not_eq('destroy')
        return saved unless key_names.all? { |name| recorded?(name) }

        saved.and(naming_key(table))
      end

      # Versions that recorded no changes, or whose recorded changes name the key.
      #: (untyped) -> untyped
      def naming_key(table)
        changes = recorded_text(table)
        key_names.map { |name| changes.matches("%#{name}%") }
                 .inject(table[:object_changes].eq(nil)) { |any, name| any.or(name) }
      end

      #: () -> Array[String]
      def key_names
        names = [@reflection.foreign_key]
        @reflection.polymorphic? ? names << @reflection.foreign_type : names
      end

      #: (String) -> bool
      def recorded?(name)
        adapter = Support.constant('PaperTrail').config.object_changes_adapter
        @versions.column_names.include?('object_changes') &&
          !adapter.respond_to?(:load_changeset) && RecordedColumns.recorded?(@owner, name)
      end

      # PostgreSQL compares a json column with text only once it is cast.
      # Only a json column on PostgreSQL takes the cast, which the SQLite
      # database mutation testing runs on never has.
      # mutant:disable
      #: (untyped) -> untyped
      def recorded_text(table)
        column = table[:object_changes]
        json = StoredTimePrecision.json_column?(@versions, 'object_changes')
        return column unless json && @versions.connection.adapter_name.match?(/postg/i)

        Support.arel::Nodes::NamedFunction.new('CAST', [column.as(Support.arel.sql('text'))])
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
