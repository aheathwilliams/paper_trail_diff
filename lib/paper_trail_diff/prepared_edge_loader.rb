# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Loads every historical identity that can participate in one association edge.
  class PreparedEdgeLoader
    EDGE_LOADERS = {
      belongs_to: :belongs_to_edge,
      has_one: :child_edge,
      has_many: :child_edge,
      has_and_belongs_to_many: :habtm_edge
    }.freeze
    private_constant :EDGE_LOADERS

    #: (PreparedRecordIndex, Array[untyped], ?start_at: untyped) -> void
    def initialize(records, root_versions, start_at: root_versions.first&.created_at)
      @records = records
      @transaction_ids = root_versions.filter_map(&:transaction_id).uniq.freeze
      @start_at = start_at
    end

    #: (untyped, Array[untyped], untyped) -> [Hash[String, Hash[Symbol, untyped]], Hash[String, Array[untyped]]?]
    def call(owner_class, owner_ids, reflection)
      loader = EDGE_LOADERS.fetch(reflection.macro)
      send(loader, owner_class, owner_ids, reflection)
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @transaction_ids: Array[untyped]
    # @rbs @start_at: untyped

    #: (untyped, Array[untyped], untyped) -> [Hash[String, Hash[Symbol, untyped]], nil]
    def belongs_to_edge(owner_class, owner_ids, reflection)
      [belongs_to_groups(owner_class, owner_ids, reflection), nil]
    end

    #: (untyped, Array[untyped], untyped) -> [Hash[String, Hash[Symbol, untyped]], nil]
    def child_edge(owner_class, owner_ids, reflection)
      [child_groups(owner_class, owner_ids, reflection), nil]
    end

    #: (untyped, Array[untyped], untyped) -> [Hash[String, Hash[Symbol, untyped]], Hash[String, Array[untyped]]]
    def habtm_edge(owner_class, _owner_ids, reflection)
      habtm_groups(owner_class, reflection)
    end

    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def belongs_to_groups(owner_class, owner_ids, reflection)
      key = scalar_foreign_key(reflection)
      return {} unless key

      grouped = {} #: Hash[String, Hash[Symbol, untyped]]
      @records.records_for(owner_class, owner_ids).each do |owner|
        id = owner.public_send(key)
        model_class = target_class(reflection, owner)
        add_identity(grouped, model_class, id) if model_class && id
      end
      grouped
    end

    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def child_groups(owner_class, owner_ids, reflection)
      key = scalar_foreign_key(reflection)
      return {} unless key

      historical = historical_child_ids(owner_class, owner_ids, reflection, key)
      live = live_child_ids(owner_class, owner_ids, reflection, key)
      owners = merge_owners(historical, live)
      group_for(reflection.klass, owners.values.flatten, owners: owners)
    end

    #: (untyped, untyped) -> [Hash[String, Hash[Symbol, untyped]], Hash[String, Array[untyped]]]
    def habtm_groups(owner_class, reflection)
      rows = habtm_rows(owner_class, reflection)
      memberships = @transaction_ids.to_h do |transaction_id|
        [transaction_id.to_s, membership_ids(rows, transaction_id)]
      end
      [group_for(reflection.klass, rows.filter_map(&:foreign_key_id)), memberships]
    end

    #: (untyped, untyped) -> Array[untyped]
    def habtm_rows(owner_class, reflection)
      owner_class.paper_trail.version_association_class.where(
        version_id: @transaction_ids,
        foreign_key_name: reflection.name.to_s
      ).to_a
    end

    #: (Array[untyped], untyped) -> Array[untyped]
    def membership_ids(rows, transaction_id)
      rows.filter_map do |row|
        row.foreign_key_id if row.version_id.to_s == transaction_id.to_s
      end.uniq
    end

    #: (untyped, Array[untyped], untyped, String) -> Hash[String, Array[untyped]]
    def historical_child_ids(
      owner_class,
      owner_ids,
      reflection,
      foreign_key
    )
      version_class = owner_class.paper_trail.version_class
      association_class = owner_class.paper_trail.version_association_class
      relation = historical_child_relation(owner_class, owner_ids, reflection, foreign_key)
      pairs = child_candidate_scope(version_class).call(relation).distinct.pluck(
        association_class.arel_table[:foreign_key_id],
        version_class.arel_table[:item_id]
      )
      group_ids_by_owner(pairs)
    end

    #: (untyped, Array[untyped], untyped, String) -> untyped
    def historical_child_relation(owner_class, owner_ids, reflection, foreign_key)
      version_class = owner_class.paper_trail.version_class
      owner_class.paper_trail.version_association_class.joins(:version).where(
        foreign_key_name: foreign_key,
        foreign_key_id: owner_ids,
        foreign_type: parent_types(owner_class)
      ).where(version_class.table_name => { item_type: reflection.klass.base_class.name })
    end

    #: (untyped) -> VersionAssociationCandidateScope
    def child_candidate_scope(version_class)
      VersionAssociationCandidateScope.new(
        version_class,
        @start_at
      )
    end

    #: (untyped, Array[untyped], untyped, String) -> Hash[String, Array[untyped]]
    def live_child_ids(owner_class, owner_ids, reflection, foreign_key)
      relation = reflection.klass.base_class.unscoped.where(foreign_key => owner_ids)
      if reflection.options[:as]
        relation = relation.where(reflection.type => parent_types(owner_class))
      end
      group_ids_by_owner(relation.pluck(foreign_key, reflection.klass.primary_key))
    end

    #: (untyped, untyped) -> untyped
    def target_class(reflection, owner)
      return reflection.klass unless reflection.polymorphic?

      Object.const_get(owner.public_send(reflection.foreign_type).to_s)
    rescue NameError
      nil
    end

    #: (Hash[String, Hash[Symbol, untyped]], untyped, untyped) -> void
    def add_identity(groups, model_class, id)
      group = groups[model_class.name.to_s] ||= { model: model_class, ids: [] }
      group.fetch(:ids) << id unless group.fetch(:ids).include?(id)
    end

    #: (untyped, Array[untyped], ?owners: Hash[String, Array[untyped]]?) -> Hash[String, Hash[Symbol, untyped]]
    def group_for(model_class, ids, owners: nil)
      unique = ids.compact.uniq
      return {} if unique.empty?

      group = { model: model_class, ids: unique } #: Hash[Symbol, untyped]
      group[:owners] = owners if owners
      { model_class.name.to_s => group }
    end

    # Keyed rather than scanned so that a wide edge stays linear in its width.
    #: (Array[Array[untyped]]) -> Hash[String, Array[untyped]]
    def group_ids_by_owner(pairs)
      grouped = {} #: Hash[String, Hash[untyped, true]]
      pairs.each do |owner_id, child_id|
        ids = grouped[owner_id.to_s] ||= {} #: Hash[untyped, true]
        ids[child_id] = true
      end
      grouped.transform_values(&:keys)
    end

    #: (Hash[String, Array[untyped]], Hash[String, Array[untyped]]) -> Hash[String, Array[untyped]]
    def merge_owners(left, right)
      left.merge(right) { |_owner, first, second| first | second }
    end

    #: (untyped) -> String?
    def scalar_foreign_key(reflection)
      key = reflection.foreign_key
      key.to_s unless key.is_a?(Array)
    end

    #: (untyped) -> Array[String?]
    def parent_types(owner_class)
      [nil, '', owner_class.name.to_s, owner_class.base_class.name.to_s].uniq
    end
  end
end
