# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Batched record states and relationship candidates for one activity range.
  class PreparedHistory
    DIRECT_RESOLVERS = {
      belongs_to: :resolve_belongs_to,
      has_one: :resolve_children,
      has_many: :resolve_children,
      has_and_belongs_to_many: :resolve_habtm
    }.freeze
    private_constant :DIRECT_RESOLVERS

    #: (PreparedRecordIndex) -> void
    def initialize(records)
      @records = records
      @edges = {} #: Hash[Array[String], Hash[String, Hash[Symbol, untyped]]]
      @unsupported = {} #: Hash[Array[String], bool]
      @habtm = {} #: Hash[Array[String], Hash[String, Array[untyped]]]
    end

    #: (untyped, untyped, Hash[String, Hash[Symbol, untyped]]) -> void
    def merge_edge(owner_class, reflection, groups)
      key = edge_key(owner_class, reflection)
      empty = {} #: Hash[String, Hash[Symbol, untyped]]
      @edges[key] = merge_groups(@edges.fetch(key, empty), groups)
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

    #: (untyped, untyped, untyped, habtm_boundary: untyped) -> [bool, Array[untyped]]
    def resolve(record, reflection, boundary, habtm_boundary:)
      return [false, []] unless supported?(record.class, reflection)

      records = if reflection.options[:through]
                  through_records(record, reflection, boundary, habtm_boundary)
                else
                  direct_records(record, reflection, boundary, habtm_boundary)
                end
      records ? [true, records] : [false, []]
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @edges: Hash[Array[String], Hash[String, Hash[Symbol, untyped]]]
    # @rbs @unsupported: Hash[Array[String], bool]
    # @rbs @habtm: Hash[Array[String], Hash[String, Array[untyped]]]

    #: (untyped, untyped) -> bool
    def supported?(owner_class, reflection)
      !@unsupported[edge_key(owner_class, reflection)] &&
        reflection.scope.nil? && !default_scoped?(reflection.klass)
    end

    #: (untyped) -> bool
    def default_scoped?(model_class)
      model_class.default_scopes?
    end

    #: (untyped, untyped, untyped, untyped) -> Array[untyped]?
    def direct_records(record, reflection, boundary, habtm_boundary)
      resolver = DIRECT_RESOLVERS.fetch(reflection.macro)
      send(resolver, record, reflection, boundary, habtm_boundary)
    end

    #: (untyped, untyped, untyped, untyped) -> Array[untyped]?
    def resolve_belongs_to(record, reflection, boundary, _habtm_boundary)
      belongs_to_records(record, reflection, boundary)
    end

    #: (untyped, untyped, untyped, untyped) -> Array[untyped]
    def resolve_children(record, reflection, boundary, _habtm_boundary)
      child_records(record, reflection, boundary)
    end

    #: (untyped, untyped, untyped, untyped) -> Array[untyped]?
    def resolve_habtm(record, reflection, boundary, habtm_boundary)
      habtm_records(record, reflection, boundary, habtm_boundary)
    end

    #: (untyped, untyped, untyped) -> Array[untyped]?
    def belongs_to_records(record, reflection, boundary)
      foreign_key = scalar_foreign_key(reflection)
      return unless foreign_key

      id = record.public_send(foreign_key)
      return [] if id.nil?

      model_class = belongs_to_class(record, reflection)
      return unless model_class && @records.loaded?(model_class, id)

      Array(@records.record_before(model_class, id, boundary)).compact
    end

    #: (untyped, untyped, untyped) -> Array[untyped]
    def child_records(record, reflection, boundary)
      edge(record.class, reflection).values.flat_map do |group|
        model_class = group.fetch(:model)
        child_ids_for(group, record).filter_map do |id|
          child = @records.record_before(model_class, id, boundary)
          child if child && member_of?(child, reflection, record)
        end
      end
    end

    #: (Hash[Symbol, untyped], untyped) -> Array[untyped]
    def child_ids_for(group, owner)
      owners = group[:owners]
      empty = [] #: Array[untyped]
      owners ? owners.fetch(owner.id.to_s, empty) : group.fetch(:ids)
    end

    #: (untyped, untyped, untyped, untyped) -> Array[untyped]?
    def habtm_records(record, reflection, boundary, habtm_boundary)
      transaction_id = transaction_id_for(habtm_boundary)
      return unless transaction_id

      empty = {} #: Hash[String, Array[untyped]]
      ids = @habtm.fetch(edge_key(record.class, reflection), empty)[transaction_id.to_s]
      return unless ids

      ids.filter_map do |id|
        @records.record_before(reflection.klass, id, boundary)
      end
    end

    #: (untyped, untyped, untyped, untyped) -> Array[untyped]?
    def through_records(record, reflection, boundary, habtm_boundary)
      handled, intermediates = resolve(
        record,
        reflection.through_reflection,
        boundary,
        habtm_boundary: habtm_boundary
      )
      return unless handled

      resolved = resolve_sources(intermediates, reflection, boundary, habtm_boundary)
      return unless resolved.all?(&:first)

      unique_records(resolved.flat_map(&:last))
    end

    #: (Array[untyped], untyped, untyped, untyped) -> Array[[bool, Array[untyped]]]
    def resolve_sources(intermediates, reflection, boundary, habtm_boundary)
      intermediates.map do |intermediate|
        resolve(
          intermediate,
          reflection.source_reflection,
          boundary,
          habtm_boundary: habtm_boundary
        )
      end
    end

    #: (untyped, untyped, untyped) -> bool
    def member_of?(child, reflection, owner)
      foreign_key = scalar_foreign_key(reflection)
      return false unless foreign_key
      return false unless child.public_send(foreign_key).to_s == owner.id.to_s
      return true unless reflection.options[:as]

      owner_types(reflection, owner).include?(child.public_send(reflection.type).to_s)
    end

    #: (untyped) -> String?
    def scalar_foreign_key(reflection)
      key = reflection.foreign_key
      key.to_s unless key.is_a?(Array)
    end

    #: (untyped, untyped) -> untyped
    def belongs_to_class(record, reflection)
      return reflection.klass unless reflection.polymorphic?

      Object.const_get(record.public_send(reflection.foreign_type).to_s)
    rescue NameError
      nil
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

    #: (Hash[String, Hash[Symbol, untyped]], Hash[String, Hash[Symbol, untyped]]) -> Hash[String, Hash[Symbol, untyped]]
    def merge_groups(existing, incoming)
      Support.merge_record_groups(existing, incoming)
    end
  end
end
