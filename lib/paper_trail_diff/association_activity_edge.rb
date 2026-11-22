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

    # The columns of a `belongs_to` key: a polymorphic one has a type column.
    #: (untyped) -> Array[String]
    def self.key_names(reflection)
      names = [reflection.foreign_key]
      reflection.polymorphic? ? names << reflection.foreign_type : names
    end

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

    # PT-AT's rows among `rows`, on `model`'s versions, that name a key held
    # in the window: the candidates, and the rows on first versions after it
    # that kept the key (see FirstKeyVersions#kept_after), in one statement.
    #: (untyped, untyped, Array[String]) -> untyped
    def held(model, rows, key_names)
      windowed = candidates(model.paper_trail.version_class, rows)
      kept = FirstKeyVersions.new(model, key_names, @time_range&.begin_time,
                                  end_at: @time_range&.end_time).kept_after(rows)
      kept ? windowed.or(kept) : windowed
    end

    #: (untyped, String) -> Symbol?
    def column_type(model, name)
      model.type_for_attribute(name).type
    end

    # The rows of `model` among `rows` that no version was saved for after
    # the window closed: an analysis reads such a row's state there, and
    # from its last version on, from the row itself, so the key the row
    # holds now is the key it held then, whether a version saved it or a
    # write without one did, such as `update_all` or a row from before
    # PaperTrail. With no end, the state at the end is the row. A database
    # compares the key with item_id only when they share a type; otherwise
    # the keys of the rows saved since are read as values, which a database
    # casts back to the key's type.
    #: (untyped, untyped) -> untyped
    def without_later_versions(model, rows)
      finish = @time_range&.end_time
      return rows unless finish
      return rows.where(after(versions_of(model), finish).arel.exists.not) if item_key?(model)

      key = model.primary_key
      saved = after(VersionQuery.for_items(model, rows.pluck(key)), finish).distinct.pluck(:item_id)
      later = { key => saved } #: Hash[untyped, untyped]
      rows.where.not(later)
    end

    #: (untyped, untyped) -> untyped
    def after(versions, finish)
      versions.where(versions.arel_table[:created_at].gt(finish))
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
    # inside it, as PT-AT recorded them on the child's own versions, or until
    # its first version after the window, where that kept the owner.
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
        held(@reflection.klass, relation, [@reflection.foreign_key, @reflection.type].compact)
      end

      private

      # @rbs @versions: untyped
      # @rbs @associations: untyped

      #: () -> Array[String?]
      def owner_types
        RecordedOwner.types(@reflection, @owner)
      end
    end

    # The owners children hold now, for children no version was saved for
    # after the window closed, such as rows from before PaperTrail or a child
    # moved with `update_columns`: as an analysis reads it, such a child held
    # its live key at the window's end, and so leads to a change further
    # down. PT-AT's rows name only the keys versions saved.
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
        without_later_versions(@target, rows)
      end

      # @rbs @target: untyped
    end

    # The owners that point at a target now and that no version was saved
    # for after the window closed, such as line items from before PaperTrail
    # that name a product, or orders moved to another customer with
    # `update_all`: as an analysis reads it, such an owner held its live key
    # at the window's end, so a change to the target, or below it, is a
    # change the owner holds. PT-AT records a belongs_to on the owner's own
    # versions, and only the keys they saved.
    class UnversionedOwner < AssociationActivityEdge
      #: (untyped, TimeRange?, ?foreign_type: String?) -> void
      def initialize(reflection, time_range, foreign_type: nil)
        super(reflection, time_range)
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
        without_later_versions(@owner, @owner.unscoped.where(held))
      end

      # @rbs @foreign_type: String?
    end

    # The owners of children whose first version ever, since the window
    # opened, may have changed the key, such as rows from before PaperTrail
    # that the window moves or detaches. PT-AT stores the keys a version
    # saved, so the owner such a child held until that version is in no row,
    # only in the version's stored state, as ActivityChildCandidateLoader
    # reads it. One saved after the window's end held the owner through it
    # too. A first version that kept the owner has a row naming it, which
    # Child reads.
    class FirstVersion < AssociationActivityEdge
      #: (untyped, TimeRange?) -> void
      def initialize(reflection, time_range)
        super
        @target = reflection.klass
        @filter_type = column_type(@target.paper_trail.version_class, 'item_id')
        @first = FirstKeyVersions.new(@target, [reflection.foreign_key, reflection.type].compact,
                                      time_range&.begin_time)
      end

      # The owners the first versions of the children `filter` selects name in
      # their stored states. An `as:` child's type must name one of the
      # owner's types, which take a child with no type, as any plain child has.
      # A version with no state for the key names no owner.
      #: (untyped) -> Array[untyped]
      def owners(filter)
        types = RecordedOwner.types(@reflection, @owner)
        @first.stored.where(item_id: filter).select(:object).filter_map do |version|
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
      # @rbs @first: FirstKeyVersions
    end

    # The owners whose first version ever, since the window opened, may have
    # changed the key, such as line items from before PaperTrail moved to
    # another product: until that version, such an owner held the key its
    # stored state holds, though PT-AT has no row for it. A first version
    # that kept the key has a row naming it, which BelongsTo reads. One saved
    # after the window's end held that key through it too.
    class FirstOwnerVersion < AssociationActivityEdge
      #: (untyped, TimeRange?) -> void
      def initialize(reflection, time_range)
        super
        @first = FirstKeyVersions.new(@owner, AssociationActivityEdge.key_names(reflection),
                                      time_range&.begin_time, end_at: time_range&.end_time)
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

      # The types the stored states of a polymorphic key's first versions
      # held, where those versions may have changed it.
      #: () -> Array[String]
      def target_types
        types = stored_states.map { |_item_id, state| state[@reflection.foreign_type] }
        types.reject(&:blank?).uniq
      end

      private

      # @rbs @first: FirstKeyVersions
      # @rbs @stored_states: Array[[untyped, Hash[String, untyped]]]?

      # Item ids and stored states of the first versions that may have
      # changed the key.
      #: () -> Array[[untyped, Hash[String, untyped]]]
      def stored_states
        @stored_states ||= @first.stored.map do |version|
          [version.item_id, version.object_deserialized]
        end
      end
    end

    # The owners that pointed at a target when the window opened or after a
    # change inside it, as PT-AT recorded them on the owners' versions, or
    # until their first version after the window, where that kept the key.
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
        rows = owner_rows(foreign_key_name: @reflection.foreign_key)
        held(@owner, rows, AssociationActivityEdge.key_names(@reflection))
          .distinct.pluck(@associations.arel_table[:foreign_type]).compact
      end

      # The owners that pointed at a target of this edge's type when the window
      # opened or after a change inside it, whichever target that was.
      #: () -> untyped
      def typed_owners
        conditions = { foreign_key_name: @reflection.foreign_key, foreign_type: @foreign_type }
        held(@owner, owner_rows(conditions), AssociationActivityEdge.key_names(@reflection))
          .select(@column)
      end

      #: (untyped) -> untyped
      def relation(filter)
        conditions = { foreign_key_name: @reflection.foreign_key, foreign_key_id: filter }
        conditions[:foreign_type] = @foreign_type if @foreign_type
        held(@owner, owner_rows(conditions), AssociationActivityEdge.key_names(@reflection))
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
