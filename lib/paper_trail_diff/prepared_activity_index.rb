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
      # Rows are cached by reflection, which a subclass shares with its base.
      @children = {} #: Hash[untyped, untyped]
      @targets = {} #: Hash[untyped, untyped]
      @rows = {} #: Hash[untyped, Hash[String, Array[untyped]]]
    end

    #: (untyped, Array[untyped]) -> void
    def register(model, ids)
      name = model.base_class.name
      @nodes[name] = (@nodes.fetch(name, []) | ids)
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def versions(model, ids)
      ids.flat_map do |id|
        @roots[[model.base_class.name, id.to_s]] || @records.versions_for_id(model, id)
      end
    end

    # Children are found by key across the whole table, so an association to
    # an STI subclass finds the rows of its siblings too. Only a row that was
    # of the class at some point belongs to it, and of that row only the
    # versions it had the class before or after.
    #: (untyped, Array[untyped]) -> Array[untyped]
    def member_ids(model, ids)
      return ids if model.descends_from_active_record?

      ids.select { |id| member_class?(model, @records.model_classes(model, id)) }
    end

    #: (untyped, Array[untyped], ActivityRange) -> Array[untyped]
    def member_versions(model, ids, range)
      all = versions(model, ids).select { |version| range.include?(version) }
      return all if model.descends_from_active_record?

      all.select do |version|
        member_class?(model, @records.model_classes(model, version.item_id, version))
      end
    end

    #: (untyped, Array[untyped], untyped, ActivityRange) -> Array[untyped]
    def child_ids(model, ids, reflection, range)
      historical, live = @children[reflection] ||= child_rows(model, reflection)
      empty = [] #: Array[untyped]
      selected = historical_ids(reflection.klass, ids, historical, range)
      selected |= ids.flat_map { |id| live.fetch(id.to_s, empty) } if range.current_end?
      selected.uniq
    end

    # The `belongs_to` targets each owner pointed at in the range: at its start
    # and after each change inside it, plus the live row at a current end.
    #: (untyped, Array[untyped], untyped, ActivityRange) -> Array[ActivityTargetCandidateLoader::Row]
    def target_rows(model, ids, reflection, range)
      historical, live = @targets[reflection] ||= target_candidates(model, reflection)
      rows = eligible_rows(model, rows_for(historical, ids), range)
      range.current_end? ? rows + rows_for(live, ids) : rows
    end

    #: (untyped, untyped) -> bool
    def loaded?(model, id)
      @records.loaded?(model, id)
    end

    # PT-AT records HABTM membership once per transaction, under the
    # association's name, so the rows are keyed by transaction id.
    #: (untyped, Array[untyped], untyped) -> Array[untyped]
    def habtm_rows(model, selected_versions, reflection)
      rows = @rows[reflection] ||= load_habtm_rows(model, reflection)
      transaction_ids(selected_versions).flat_map { |id| rows.fetch(id.to_s, []) }
    end

    private

    # @rbs @records: PreparedRecordIndex
    # @rbs @range: ActivityRange
    # @rbs @roots: Hash[Array[String], Array[untyped]]
    # @rbs @nodes: Hash[String, Array[untyped]]
    # @rbs @children: Hash[untyped, untyped]
    # @rbs @targets: Hash[untyped, untyped]
    # @rbs @rows: Hash[untyped, Hash[String, Array[untyped]]]

    #: (untyped, Array[untyped]) -> bool
    def member_class?(model, classes)
      classes.any? { |model_class| model_class <= model }
    end

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
      name = model.base_class.name
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
      rows.select do |row|
        eligible_version?(model, row.owner_id, row.created_at, row.event, range) &&
          range.recorded_before_end?(row.created_at, row.version_id)
      end
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

    #: (untyped, untyped) -> Hash[String, Array[untyped]]
    def load_habtm_rows(model, reflection)
      model.paper_trail.version_association_class.where(
        version_id: transaction_ids(versions(model, node_ids(model))),
        foreign_key_name: reflection.name
      ).group_by { |row| row.version_id.to_s }
    end

    # A version without a transaction id names no rows, so it can stay in.
    #: (Array[untyped]) -> Array[untyped]
    def transaction_ids(versions)
      versions.map { |version| version.transaction_id if version.respond_to?(:transaction_id) }.uniq
    end
  end
end
