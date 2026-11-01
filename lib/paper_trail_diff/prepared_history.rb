# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Batched record states and relationship candidates for one activity range.
  class PreparedHistory
    attr_reader :activity_index #: PreparedActivityIndex?

    DIRECT_RESOLVERS = {
      belongs_to: :resolve_belongs_to,
      has_one: :resolve_children,
      has_many: :resolve_children,
      has_and_belongs_to_many: :habtm_records
    }.freeze
    private_constant :DIRECT_RESOLVERS

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
      resolver = DIRECT_RESOLVERS.fetch(reflection.macro)
      send(resolver, record, reflection, boundary, habtm_boundary, ranked)
    end

    #: (untyped, untyped, untyped, untyped, bool) -> Array[untyped]?
    def resolve_belongs_to(record, reflection, boundary, _habtm_boundary, ranked)
      belongs_to_records(record, reflection, boundary, ranked)
    end

    #: (untyped, untyped, untyped, untyped, bool) -> Array[untyped]
    def resolve_children(record, reflection, boundary, _habtm_boundary, ranked)
      child_records(record, reflection, boundary, ranked)
    end

    #: (untyped, untyped, untyped, bool) -> Array[untyped]?
    def belongs_to_records(record, reflection, boundary, ranked)
      foreign_key = scalar_foreign_key(reflection)
      return unless foreign_key

      id = record.public_send(foreign_key)
      return [] if id.nil?

      model_class = AssociationTraversal.belongs_to_target(reflection, record)
      return unless model_class && @conditions.call(reflection, model_class, ranked: ranked) &&
                    @records.loaded?(model_class, id)

      target = Array(@records.record_before(model_class, id, boundary)).compact
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
      @conditions.select(reflection, children, ranked: ranked)
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

    # A has_many through reads its parts unranked, as its query does. Its own
    # scope applies to each row, and a ranked read then keeps a record reached
    # twice as one member.
    #: (untyped, untyped, untyped, untyped, bool) -> Array[untyped]?
    def through_records(record, reflection, boundary, habtm_boundary, ranked)
      read = lambda do |owner, part|
        resolve(owner, part, boundary, habtm_boundary: habtm_boundary,
                                       ranked: ranked && !reflection.collection?)
      end
      rows = through_rows(record, reflection, read)
      return unless rows

      rows = @conditions.select(reflection, rows, ranked: ranked)
      ranked ? unique_records(rows) : rows
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
      foreign_key = scalar_foreign_key(reflection)
      return false unless foreign_key
      return false unless child.public_send(foreign_key).to_s == owner.id.to_s
      return false unless AssociationTraversal.sti_member?(reflection.klass, child.attributes)
      return true unless reflection.options[:as]

      owner_types(reflection, owner).include?(child.public_send(reflection.type).to_s)
    end

    #: (untyped) -> String?
    def scalar_foreign_key(reflection)
      key = reflection.foreign_key
      key.to_s unless key.is_a?(Array)
    end

    #: (untyped, untyped) -> Array[String]
    def owner_types(reflection, owner)
      types = [owner.class.name, owner.class.base_class.name, reflection.active_record.name]
      types.map(&:to_s).uniq
    end

    #: (untyped) -> untyped
    def transaction_id_for(boundary)
      boundary.transaction_id
    end

    #: (Array[untyped]) -> Array[untyped]
    def unique_records(records)
      records.uniq { |record| [record.class.base_class.name, record.id.to_s] }
    end

    #: (untyped, untyped) -> Array[String]
    def edge_key(owner_class, reflection)
      [owner_class.base_class.name.to_s, reflection.name.to_s]
    end
  end
end
