# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Loads every historical identity that can participate in one association edge.
  class PreparedEdgeLoader
    # A history shares `children` with its activity index, which reads the
    # children this finds again.
    #: (PreparedRecordIndex, Array[untyped], ?start_at: untyped, ?children: PreparedChildCandidates) -> void
    def initialize(records, root_versions, start_at: root_versions.first&.created_at,
                   children: PreparedChildCandidates.new(start_at))
      @records = records
      @transaction_ids = root_versions.filter_map(&:transaction_id)
      @children = children
    end

    # HABTM alone also returns each root transaction's members.
    #: (untyped, Array[untyped], untyped) -> [Hash[String, Hash[Symbol, untyped]], Hash[String, Array[untyped]]?]
    def call(owner_class, owner_ids, reflection)
      case reflection.macro
      when :belongs_to then [belongs_to_groups(owner_class, owner_ids, reflection), nil]
      when :has_and_belongs_to_many then habtm_groups(owner_class, reflection)
      else [child_groups(owner_class, owner_ids, reflection), nil]
      end
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @transaction_ids: Array[untyped]
    # @rbs @children: PreparedChildCandidates

    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def belongs_to_groups(owner_class, owner_ids, reflection)
      key = AssociationKey.scalar_foreign_key(reflection)
      return {} unless key
      unless reflection.polymorphic?
        return group_for(reflection.klass,
                         @records.attribute_values_for(owner_class, owner_ids, key))
      end

      grouped = {} #: Hash[String, Hash[Symbol, untyped]]
      # Grouping only decides what to preload, so a type that names no class is
      # left to raise where that state is read.
      @records.records_for(owner_class, owner_ids).each do |owner|
        id = owner.public_send(key)
        type = owner.public_send(reflection.foreign_type).to_s
        model_class = AssociationTraversal.named_class(type)
        add_identity(grouped, model_class, id) if model_class && id
      end
      grouped
    end

    # Each owner's children, recorded or live, each once.
    #: (untyped, Array[untyped], untyped) -> Hash[String, Hash[Symbol, untyped]]
    def child_groups(owner_class, owner_ids, reflection)
      historical, live = @children.call(owner_class, owner_ids, reflection)
      empty = [] #: Array[untyped]
      owners = owner_ids.to_h do |id|
        key = id.to_s
        [key, historical.fetch(key, empty).map { |row| row.fetch(1) } | live.fetch(key, empty)]
      end
      group_for(reflection.klass, owners.values.flatten, owners: owners)
    end

    # A transaction more than one owner recorded members in is left out, so
    # its read falls back to HistoricalAssociationReifier, which raises.
    #: (untyped, untyped) -> [Hash[String, Hash[Symbol, untyped]], Hash[String, Array[untyped]]]
    def habtm_groups(owner_class, reflection)
      rows = habtm_rows(owner_class, reflection)
      shared = HabtmTransactionOwners.new(owner_class, reflection).shared(rows.map(&:version_id))
      memberships = @transaction_ids.to_h do |transaction_id|
        [transaction_id.to_s, membership_ids(rows, transaction_id)]
      end
      [group_for(reflection.klass, rows.map(&:foreign_key_id)), memberships.except(*shared)]
    end

    #: (untyped, untyped) -> Array[untyped]
    def habtm_rows(owner_class, reflection)
      owner_class.paper_trail.version_association_class.where(
        version_id: @transaction_ids,
        foreign_key_name: reflection.name
      )
    end

    #: (Array[untyped], untyped) -> Array[untyped]
    def membership_ids(rows, transaction_id)
      rows.filter_map do |row|
        row.foreign_key_id if row.version_id.to_s == transaction_id.to_s
      end
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
      { model_class.name => group }
    end
  end
end
