# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Shares association event discovery across every root in a prepared graph.
  class PreparedActivityIndex
    #: (PreparedRecordIndex, Array[untyped], start_at: untyped, end_at: untyped) -> void
    def initialize(records, root_versions, start_at:, end_at:)
      @records = records
      @range = ActivityRange.new(start_at, end_at)
      @roots = root_versions.group_by { |version| [version.item_type, version.item_id.to_s] }
      @nodes = {} #: Hash[String, Array[untyped]]
      @children = {} #: Hash[Array[String], untyped]
      @targets = {} #: Hash[Array[String], untyped]
      @rows = {} #: Hash[Array[String], Hash[String, Array[untyped]]]
    end

    #: (untyped, Array[untyped]) -> void
    def register(model, ids)
      name = model.base_class.name.to_s
      @nodes[name] = (@nodes.fetch(name, []) | ids)
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def versions(model, ids)
      ids.flat_map do |id|
        key = [model.base_class.name.to_s, id.to_s]
        @roots[key] || @records.versions_for_id(model, id)
      end
    end

    #: (untyped, Array[untyped], untyped, ActivityRange) -> Array[untyped]
    def child_ids(model, ids, reflection, range)
      key = [model.base_class.name.to_s, reflection.name.to_s]
      historical, live = @children[key] ||= child_rows(model, reflection)
      empty = [] #: Array[untyped]
      selected = historical_ids(reflection.klass, ids, historical, range)
      selected |= ids.flat_map { |id| live.fetch(id.to_s, empty) } if range.current_end?
      selected.uniq
    end

    # The `belongs_to` targets each owner pointed at in the range: at its start
    # and after each change inside it, plus the live row at a current end.
    #: (untyped, Array[untyped], untyped, ActivityRange) -> Array[ActivityTargetCandidateLoader::Row]
    def target_rows(model, ids, reflection, range)
      key = [model.base_class.name.to_s, reflection.name.to_s]
      historical, live = @targets[key] ||= target_candidates(model, reflection)
      rows = eligible_rows(model, rows_for(historical, ids), range)
      range.current_end? ? rows + rows_for(live, ids) : rows
    end

    #: (untyped, untyped) -> bool
    def loaded?(model, id)
      @records.loaded?(model, id)
    end

    #: (untyped, Array[untyped], untyped, ?transactions: bool) -> Array[untyped]
    def association_rows(model, selected_versions, reflection, transactions: false)
      key = [model.base_class.name.to_s, reflection.name.to_s]
      rows = @rows[key] ||= load_association_rows(model, reflection, transactions)
      version_ids(selected_versions, transactions).flat_map { |id| rows.fetch(id.to_s, []) }
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @range: ActivityRange
    # @rbs @roots: Hash[Array[String], Array[untyped]]
    # @rbs @nodes: Hash[String, Array[untyped]]
    # @rbs @children: Hash[Array[String], untyped]
    # @rbs @targets: Hash[Array[String], untyped]
    # @rbs @rows: Hash[Array[String], Hash[String, Array[untyped]]]

    #: (untyped, Array[untyped], untyped, ActivityRange) -> Array[untyped]
    def historical_ids(model, ids, historical, range)
      empty = [] #: Array[untyped]
      ids.flat_map do |id|
        historical.fetch(id.to_s, empty).filter_map do |row|
          _owner, child_id, timestamp, event = row
          child_id if eligible_version?(model, child_id, timestamp, event, range)
        end
      end
    end

    #: (untyped) -> Array[untyped]
    def node_ids(model)
      name = model.base_class.name.to_s
      @nodes.fetch(name) do
        raise ConfigurationError,
              "prepared activity graph is missing #{name}; " \
              'register the model before collecting activity'
      end
    end

    #: (untyped, untyped) -> untyped
    def child_rows(model, reflection)
      loader = ActivityChildCandidateLoader.new(
        model, node_ids(model), reflection, @range
      )
      [loader.historical_rows.group_by { |row| row.first.to_s },
       loader.current_pairs.group_by { |row| row.first.to_s }
             .transform_values { |rows| rows.map(&:last) }]
    end

    #: (Hash[String, Array[ActivityTargetCandidateLoader::Row]], Array[untyped]) -> Array[ActivityTargetCandidateLoader::Row]
    def rows_for(grouped, ids)
      ids.flat_map { |id| grouped[id.to_s] || [] }
    end

    #: (untyped, Array[ActivityTargetCandidateLoader::Row], ActivityRange) -> Array[ActivityTargetCandidateLoader::Row]
    def eligible_rows(model, rows, range)
      rows.select { |row| eligible_version?(model, row.owner_id, row.created_at, row.event, range) }
    end

    #: (untyped, untyped) -> untyped
    def target_candidates(model, reflection)
      loader = ActivityTargetCandidateLoader.new(model, node_ids(model), reflection, @range)
      [loader.historical_rows.group_by { |row| row.owner_id.to_s },
       loader.current_rows.group_by { |row| row.owner_id.to_s }]
    end

    # Mirrors VersionAssociationCandidateScope's before-window rule. The loaded
    # series includes changes to other owners too, so an old membership cannot
    # survive a later pre-window reassignment just because that owner is absent.
    #: (untyped, untyped, untyped, String?, ActivityRange) -> bool
    def eligible_version?(model, id, timestamp, event, range)
      return timestamp <= range.end_time if timestamp >= range.start_time
      return false if event == 'destroy'

      later = @records.versions_for_id(model, id)
                      .bsearch { |version| version.created_at > timestamp }
      !later || later.created_at >= range.start_time
    end

    #: (untyped, untyped, bool) -> Hash[String, Array[untyped]]
    def load_association_rows(model, reflection, transactions)
      all_versions = versions(model, node_ids(model))
      foreign_key = transactions ? reflection.name.to_s : reflection.foreign_key.to_s
      model.paper_trail.version_association_class.where(
        version_id: version_ids(all_versions, transactions), foreign_key_name: foreign_key
      ).to_a.group_by { |row| row.version_id.to_s }
    end

    #: (Array[untyped], bool) -> Array[untyped]
    def version_ids(versions, transactions)
      if transactions
        versions.filter_map do |version|
          version.transaction_id if version.respond_to?(:transaction_id)
        end.uniq
      else
        versions.map(&:id)
      end
    end
  end
end
