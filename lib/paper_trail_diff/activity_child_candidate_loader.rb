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
      owner_slices.flat_map do |owners|
        relation = scope.call(historical_relation(version_class, foreign_key, owners))
        relation = relation.where(there_by_end(version_class)) if @end_at
        typed_rows(pluck_rows(relation, version_class))
      end
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

    # A version saved by the end, or any version of a child that was not
    # created after it.
    #: (untyped) -> untyped
    def there_by_end(version_class)
      versions = version_class.arel_table
      created = VersionQuery.created_after(versions, versions[:item_type], versions[:item_id],
                                           @end_at)
      versions[:created_at].lteq(@end_at).or(created.not)
    end

    #: () -> untyped
    def live_by_end
      children = @reflection.klass.base_class
      VersionQuery.created_after(
        @parent_class.paper_trail.version_class.arel_table,
        children.name, children.arel_table[children.primary_key], @end_at
      ).not
    end

    # A live row is matched to its versions in the database only where it
    # compares an item_id with a key held as the same type; elsewhere every
    # live child is read, as without an end.
    #: () -> bool
    def comparable_keys?
      return false unless @end_at

      children = @reflection.klass.base_class
      key = children.primary_key
      item_ids = @parent_class.paper_trail.version_class.type_for_attribute('item_id')
      key.is_a?(String) && children.type_for_attribute(key).type == item_ids.type
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
