# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Loads the `belongs_to` targets owners pointed at from a start onward: at
  # the start, after each change since, and in the live row.
  #
  # PT-AT records a version's foreign keys as they stood after its change, so
  # the target at the start comes from the latest version before it. Reading
  # only the owners' versions after the start misses a target whose owner did
  # not change there -- an author renamed under an article nobody edited.
  class ActivityTargetCandidateLoader
    # A plain class rather than Data.define, which arrived in Ruby 3.2 while this
    # gem supports 3.1.
    class Row
      attr_reader :owner_id #: untyped
      attr_reader :foreign_key_id #: untyped
      attr_reader :foreign_type #: String?
      attr_reader :created_at #: untyped
      attr_reader :event #: String?

      #: (untyped, untyped, String?, ?untyped, ?String?) -> void
      def initialize(owner_id, foreign_key_id, foreign_type, created_at = nil, event = nil)
        @owner_id = owner_id
        @foreign_key_id = foreign_key_id
        @foreign_type = foreign_type
        @created_at = created_at
        @event = event
        freeze
      end
    end

    #: (untyped, Array[untyped], untyped, untyped) -> void
    def initialize(owner_class, owner_ids, reflection, start_at)
      @owner_class = owner_class
      @owner_ids = owner_ids
      @reflection = reflection
      @start_at = start_at
    end

    # Queries shared by a batch's roots keep the owner and timestamp needed to
    # partition its candidates back into each root's exact activity range.
    #: () -> Array[Row]
    def historical_rows
      return [] if composite_foreign_key?

      version_class = @owner_class.paper_trail.version_class
      scope = VersionAssociationCandidateScope.new(version_class, @start_at)
      owner_slices.flat_map do |owners|
        relation = scope.call(historical_relation(version_class, owners))
        historical_columns(relation, version_class).map do |row|
          owner_id, id, type, created_at, event = row
          Row.new(Support.record_id(@owner_class, owner_id), id, type, created_at, event)
        end
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
    # @rbs @start_at: untyped

    # Each statement reads the targets of 500 owners.
    #: () -> Enumerator[Array[untyped], untyped]
    def owner_slices
      @owner_ids.each_slice(Support::IDS_PER_STATEMENT)
    end

    #: (untyped, Array[untyped]) -> untyped
    def historical_relation(version_class, owners)
      VersionTable.joined(association_class, version_class)
                  .where(foreign_key_name: @reflection.foreign_key)
                  .where(version_class.table_name => {
                           item_type: @owner_class.base_class.name, item_id: owners
                         })
    end

    #: (untyped, untyped) -> Array[Array[untyped]]
    def historical_columns(relation, version_class)
      versions = version_class.arel_table
      associations = association_class.arel_table
      relation.pluck(versions[:item_id], associations[:foreign_key_id],
                     associations[:foreign_type], versions[:created_at], versions[:event])
    end

    # A polymorphic key names its target in a type column; any other names it
    # in the reflection, so no type is read. Like the history, the live read
    # takes owners of every class under the base class: a batch can ask for
    # the owners of an association through one subclass.
    #: () -> Array[Array[untyped]]
    def live_rows
      key = @reflection.foreign_key
      owner_slices.flat_map do |owners|
        relation = @owner_class.base_class.unscoped.where(@owner_class.primary_key => owners)
        next relation.pluck(@owner_class.primary_key, key) unless @reflection.polymorphic?

        relation.pluck(@owner_class.primary_key, key, @reflection.foreign_type)
      end
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
