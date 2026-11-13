# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Loads the children of a has_many or has_one that its owners had from a
  # start onward, from PT-AT's version associations and the live rows.
  # Prepared history and activity both read children through it. A composite
  # foreign key reads none, as loaded history cannot index it.
  #
  # A history that ends leaves out the children created after its end (see
  # VersionQuery.created_after), which no state up to the end holds: read
  # with the rest, each would bring its versions and its row, and a range
  # long past would cost more with every child its owners have gained since.
  class ActivityChildCandidateLoader
    #: (untyped, Array[untyped], untyped, untyped, ?untyped) -> void
    def initialize(parent_class, parent_ids, reflection, start_at, end_at = nil)
      @parent_class = parent_class
      @parent_ids = parent_ids
      @reflection = reflection
      @start_at = start_at
      @end_at = end_at
      @foreign_key = AssociationKey.scalar_foreign_key(reflection)
    end

    # Queries shared by a batch's roots keep the owner and timestamp needed to
    # partition its candidates back into each root's exact activity range.
    #: () -> Array[Array[untyped]]
    def historical_rows
      foreign_key = @foreign_key
      return [] unless foreign_key

      version_class = @parent_class.paper_trail.version_class
      scope = VersionAssociationCandidateScope.new(version_class, @start_at)
      recorded = owner_slices.flat_map do |owners|
        relation = scope.call(historical_relation(version_class, foreign_key, owners))
        relation = relation.where(there_by_end(version_class)) if @end_at
        pluck_rows(relation, version_class)
      end
      typed_rows((recorded + first_owner_rows(foreign_key)).uniq)
    end

    #: () -> Array[Array[untyped]]
    def current_pairs
      foreign_key = @foreign_key
      return [] unless foreign_key

      owner_slices.flat_map do |owners|
        live_relation(foreign_key, owners).pluck(foreign_key, @reflection.klass.primary_key)
      end
    end

    private

    # @rbs @parent_class: untyped
    # @rbs @parent_ids: Array[untyped]
    # @rbs @reflection: untyped
    # @rbs @start_at: untyped
    # @rbs @end_at: untyped
    # @rbs @foreign_key: String?

    # Every row of the table, as history reads them: an STI subclass's
    # siblings are left out where children are resolved.
    #: (String, Array[untyped]) -> untyped
    def live_relation(foreign_key, owners)
      relation = @reflection.klass.base_class.unscoped.where(foreign_key => owners)
      relation = relation.where(@reflection.type => parent_types) if @reflection.type
      comparable_keys? ? relation.where(live_by_end) : relation
    end

    # Any version of a child that was not created after the end. A version
    # saved by the end precedes any create after it, so it is always kept.
    #: (untyped) -> untyped
    def there_by_end(version_class)
      versions = version_class.arel_table
      VersionQuery.created_after(versions, versions[:item_type], versions[:item_id], @end_at).not
    end

    # The child class is quoted as its name, which its versions record.
    #: () -> untyped
    def live_by_end
      children = @reflection.klass.base_class
      VersionQuery.created_after(
        @parent_class.paper_trail.version_class.arel_table,
        children, children.arel_table[children.primary_key], @end_at
      ).not
    end

    # A live row is matched to its versions in the database only where it
    # compares an item_id with a key held as the same type; elsewhere every
    # live child is read, as without an end.
    #: () -> bool
    def comparable_keys?
      return false unless @end_at

      children = @reflection.klass
      item_ids = @parent_class.paper_trail.version_class.type_for_attribute('item_id')
      children.type_for_attribute(children.primary_key).type == item_ids.type
    end

    #: (Array[Array[untyped]]) -> Array[Array[untyped]]
    def typed_rows(rows)
      rows.map do |owner_id, item_id, created_at, event|
        [owner_id, Support.record_id(@reflection.klass, item_id), created_at, event]
      end
    end

    # Each statement reads the children of 500 owners.
    #: () -> Enumerator[Array[untyped], untyped]
    def owner_slices
      @parent_ids.each_slice(Support::IDS_PER_STATEMENT)
    end

    #: (untyped, String, Array[untyped]) -> untyped
    def historical_relation(version_class, foreign_key, owners)
      associations = @parent_class.paper_trail.version_association_class
      VersionTable.joined(associations, version_class).where(
        foreign_key_name: foreign_key,
        foreign_key_id: owners,
        foreign_type: parent_types
      ).where(version_class.table_name => { item_type: @reflection.klass.base_class.name })
    end

    # PT-AT stores the keys a version saved, so the owner a child held before
    # its first version is in no row when that version is not a create: the
    # child was made without one, and its first version's state, which holds
    # that owner, is read instead.
    #: (String) -> Array[Array[untyped]]
    def first_owner_rows(foreign_key)
      held = @parent_ids.to_set(&:to_s)
      first_versions.filter_map do |version|
        state = version.object && version.object_deserialized
        owner = state[foreign_key] if state
        # An `as:` child's type column must name one of the owner's types,
        # which take a child with no type, as any plain child has.
        next unless held.include?(owner.to_s) && parent_types.include?(state[@reflection.type])

        [owner, version.item_id, version.created_at, version.event]
      end
    end

    # The first version of each child since the start, unless it created its
    # child: a create holds no state, and every child created after the
    # range would be read for nothing. One saved after the end holds the
    # state the child had there too. A model PaperTrail does not version has
    # none.
    #: () -> untyped
    def first_versions
      return [] unless Support.versioned?(@reflection.klass)

      relation = VersionQuery.for_model(@reflection.klass).where.not(event: 'create')
      versions = relation.arel_table
      relation = relation.where(VersionQuery.no_earlier_version(versions))
      relation = relation.where(versions[:created_at].gteq(@start_at)) if @start_at
      relation
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
      RecordedOwner.types(@reflection, @parent_class)
    end
  end
end
