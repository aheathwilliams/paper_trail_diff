# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Batched record states and relationship candidates for one activity range.
  class PreparedHistory
    attr_reader :activity_index #: PreparedActivityIndex?

    #: (PreparedRecordIndex, ?activity_index: PreparedActivityIndex?) -> void
    def initialize(records, activity_index: nil)
      @records = records
      @conditions = ScopeCondition::Cache.new
      @state_reader = PreparedStateAssociationReader.new(records, method(:edge), @conditions)
      @activity_index = activity_index
      @edges = {} #: Hash[Array[String], Hash[String, Hash[Symbol, untyped]]]
      @unsupported = {} #: Hash[Array[String], bool]
      @habtm = {} #: Hash[Array[String], Hash[String, Array[untyped]]]
    end

    # Where the earliest transaction open at a window's start began; see
    # PreparedHistoryLoader. Nil for a history that was not asked, or where
    # none was open.
    attr_accessor :reach #: untyped

    # When the history was read from.
    #: () -> untyped
    def start_time = @records.start_time

    #: () -> Array[untyped]
    def versions = @records.versions

    # See PreparedRecordIndex#reading.
    #: (TransactionEnds) { () -> void } -> void
    def reading(ends, &block)
      @records.reading(ends, &block)
    end

    # See PreparedRecordIndex#transaction_ends.
    #: (Array[untyped]) -> TransactionEnds
    def transaction_ends(versions) = @records.transaction_ends(versions)

    #: () -> TransactionEnds?
    def reading_ends = @records.reading_ends

    # Returns every group the edge now holds.
    #: (untyped, untyped, Hash[String, Hash[Symbol, untyped]]) -> Hash[String, Hash[Symbol, untyped]]
    def merge_edge(owner_class, reflection, groups)
      key = edge_key(owner_class, reflection)
      empty = {} #: Hash[String, Hash[Symbol, untyped]]
      @edges[key] = Support.merge_record_groups(@edges.fetch(key, empty), groups)
    end

    #: (untyped, untyped) -> Hash[String, Hash[Symbol, untyped]]
    def edge(owner_class, reflection)
      empty = {} #: Hash[String, Hash[Symbol, untyped]]
      @edges.fetch(edge_key(owner_class, reflection), empty)
    end

    #: (untyped, untyped) -> void
    def mark_unsupported(owner_class, reflection)
      @unsupported[edge_key(owner_class, reflection)] = true
    end

    #: (untyped, untyped, Hash[String, Array[untyped]]) -> void
    def register_habtm(owner_class, reflection, memberships)
      @habtm[edge_key(owner_class, reflection)] = memberships.transform_keys(&:to_s)
    end

    #: (untyped, untyped, untyped) -> [Hash[untyped, untyped], Hash[untyped, untyped]]?
    def record_transition(model_class, id, version)
      @records.transition(model_class, id, version)
    end

    #: (untyped, untyped, untyped, ?direct: bool) -> [bool, untyped]
    def record_after(model_class, id, version, direct: false)
      @records.record_after(model_class, id, version, direct: direct)
    end

    #: (PreparedRecordState, untyped, untyped) -> [bool, Array[PreparedRecordState]]
    def snapshot_states(owner, reflection, boundary)
      @state_reader.call(owner, reflection, boundary)
    end

    # Unranked, as a part of a has_many through is read, it returns every row
    # the part's conditions admit, a record reached twice appearing twice.
    #: (untyped, untyped, untyped, habtm_boundary: untyped, ?ranked: bool) -> [bool, Array[untyped]]
    def resolve(record, reflection, boundary, habtm_boundary:, ranked: true)
      return [false, []] unless supported?(record.class, reflection, ranked)

      records = if reflection.options[:through]
                  through_records(record, reflection, boundary, habtm_boundary, ranked)
                else
                  direct_records(record, reflection, boundary, habtm_boundary, ranked)
                end
      records ? [true, records] : [false, []]
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @state_reader: PreparedStateAssociationReader
    # @rbs @edges: Hash[Array[String], Hash[String, Hash[Symbol, untyped]]]
    # @rbs @unsupported: Hash[Array[String], bool]
    # @rbs @habtm: Hash[Array[String], Hash[String, Array[untyped]]]
    # @rbs @conditions: ScopeCondition::Cache

    # A polymorphic target's class is known only once a record names it, so
    # belongs_to_records reads its scope for each record instead.
    #: (untyped, untyped, bool) -> bool
    def supported?(owner_class, reflection, ranked)
      !@unsupported[edge_key(owner_class, reflection)] &&
        (reflection.polymorphic? || !@conditions.call(reflection, ranked: ranked).nil?)
    end

    #: (untyped, untyped, untyped, untyped, bool) -> Array[untyped]?
    def direct_records(record, reflection, boundary, habtm_boundary, ranked)
      case reflection.macro
      when :belongs_to then belongs_to_records(record, reflection, boundary, ranked)
      when :has_one, :has_many then child_records(record, reflection, boundary, ranked)
      when :has_and_belongs_to_many
        habtm_records(record, reflection, boundary, habtm_boundary, ranked)
      end
    end

    #: (untyped, untyped, untyped, bool) -> Array[untyped]?
    def belongs_to_records(record, reflection, boundary, ranked)
      foreign_key = AssociationKey.scalar_foreign_key(reflection)
      return unless foreign_key

      id = record.public_send(foreign_key)
      return [] if id.nil?

      model_class = AssociationTraversal.belongs_to_target(reflection, record)
      return unless model_class && @conditions.call(reflection, model_class, ranked: ranked) &&
                    @records.loaded?(model_class, id)

      # An STI subclass reads no sibling's row, as its type condition reads none.
      rows = Array(@records.record_before(model_class, id, boundary)).compact #: Array[untyped]
      target = rows.select { |row| AssociationTraversal.sti_member?(model_class, row.attributes) }
      @conditions.select(reflection, target, model_class, ranked: ranked)
    end

    #: (untyped, untyped, untyped, bool) -> Array[untyped]
    def child_records(record, reflection, boundary, ranked)
      children = edge(record.class, reflection).values.flat_map do |group|
        model_class = group.fetch(:model)
        child_ids_for(group, record).filter_map do |id|
          child = @records.record_before(model_class, id, boundary)
          child if child && member_of?(child, reflection, record)
        end
      end
      one_if_has_one(reflection, @conditions.select(reflection, children, ranked: ranked), ranked)
    end

    # A ranked has_one keeps one of its records, as the state path reads it
    # (see ScopeCondition#first). An unranked read is a part of a has_many
    # through, whose join keeps every row.
    #: (untyped, Array[untyped], bool) -> Array[untyped]
    def one_if_has_one(reflection, records, ranked)
      return records unless ranked && reflection.has_one?

      condition = @conditions.call(reflection, ranked: ranked) #: ScopeCondition
      condition.first(records)
    end

    #: (Hash[Symbol, untyped], untyped) -> Array[untyped]
    def child_ids_for(group, owner)
      owners = group[:owners]
      empty = [] #: Array[untyped]
      owners ? owners.fetch(owner.id.to_s, empty) : group.fetch(:ids)
    end

    # PT-AT records a checkpoint's membership as it is when the checkpoint is
    # saved, so a tag attached earlier in the checkpoint's own transaction is a
    # member there, unlike other associations, which a version reads as they
    # were before its transaction. A member created in that transaction has no
    # earlier state, so it is read as it was created, from its creation on.
    # The checkpoint's membership also stands for earlier points, since the
    # previous root version; the member did not exist at those yet.
    #: (untyped, untyped, untyped, untyped, bool) -> Array[untyped]?
    def habtm_records(record, reflection, boundary, habtm_boundary, ranked)
      transaction_id = transaction_id_for(habtm_boundary)
      return unless transaction_id

      empty = {} #: Hash[String, Array[untyped]]
      ids = @habtm.fetch(edge_key(record.class, reflection), empty)[transaction_id.to_s]
      return unless ids

      created = VersionBoundary.transaction_id(boundary).to_s == transaction_id.to_s
      members = ids.filter_map { |id| habtm_member(reflection.klass, id, boundary, created) }
      @conditions.select(reflection, members, ranked: ranked)
    end

    #: (untyped, untyped, untyped, bool) -> untyped
    def habtm_member(model_class, id, boundary, created)
      @records.record_before(model_class, id, boundary) ||
        (@records.record_created_in(model_class, id, boundary) if created)
    end

    # A through reads its parts unranked, as its one query joins every row of
    # each: a has_one part keeps no single row there. Its own scope applies to
    # each row, and a ranked read then keeps a record reached twice as one
    # member, or a has_one through its first.
    #: (untyped, untyped, untyped, untyped, bool) -> Array[untyped]?
    def through_records(record, reflection, boundary, habtm_boundary, ranked)
      read = lambda do |owner, part|
        resolve(owner, part, boundary, habtm_boundary: habtm_boundary, ranked: false)
      end
      rows = through_rows(record, reflection, read)
      return unless rows

      rows = @conditions.select(reflection, rows, ranked: ranked)
      ranked ? one_if_has_one(reflection, unique_records(rows), ranked) : rows
    end

    # The source records of each join record, once for each join.
    #: (untyped, untyped, ^(untyped, untyped) -> [bool, Array[untyped]]) -> Array[untyped]?
    def through_rows(record, reflection, read)
      handled, joins = read.call(record, reflection.through_reflection)
      return unless handled

      joins = joins.select { |join| AssociationTraversal.source_type_join?(reflection, join) }
      resolved = joins.map { |join| read.call(join, reflection.source_reflection) }
      resolved.flat_map(&:last) if resolved.all?(&:first)
    end

    #: (untyped, untyped, untyped) -> bool
    def member_of?(child, reflection, owner)
      foreign_key = AssociationKey.scalar_foreign_key(reflection)
      return false unless foreign_key
      return false unless child.public_send(foreign_key).to_s == owner.id.to_s
      return false unless AssociationTraversal.sti_member?(reflection.klass, child.attributes)
      return true unless reflection.options[:as]

      AssociationTraversal.owner_type(reflection) == child.public_send(reflection.type).to_s
    end

    #: (untyped) -> untyped
    def transaction_id_for(boundary)
      boundary.transaction_id
    end

    #: (Array[untyped]) -> Array[untyped]
    def unique_records(records)
      records.uniq { |record| Support.record_identity(record.class, record.id) }
    end

    #: (untyped, untyped) -> Array[String]
    def edge_key(owner_class, reflection)
      [owner_class.base_class.name.to_s, reflection.name.to_s]
    end
  end
end
