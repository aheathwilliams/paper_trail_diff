# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Analyzes missing roots together without pretending that they have live rows.
  class DeletedAnalysisBatch
    # `context_required` reads a root that did not change in the window from
    # the version after it, so its associations' activity can be reported.
    #: (untyped, identities: Array[Array[String]], time_range: TimeRange?, analyzer: untyped, history_preparer: untyped, version_scope: untyped, context_required: bool) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      model, identities:, time_range:, analyzer:, history_preparer:, version_scope:,
      context_required:
    )
      @model = model
      @context_required = context_required
      @identities = identities
      @time_range = time_range
      @analyzer = analyzer
      @history_preparer = history_preparer
      @version_scope = version_scope
    end

    #: () -> Hash[Array[String], Analysis?]
    def call
      destroys = destroy_versions
      records = historical_roots(destroys)
      windows = TransactionCut.batch_windows(records, @time_range)
      selected = plans(records, destroys, windows)
      prepare(records, selected, windows)
      analyses = records.to_h do |record|
        key = Endpoint.identity(record)
        plan = selected.fetch(key)
        window = windows.fetch(key, @time_range)
        [key, plan.empty? ? Analysis.empty : @analyzer.call(record, plan, window)]
      end
      with_unavailable(analyses)
    end

    private

    #: (Hash[Array[String], Analysis]) -> Hash[Array[String], Analysis?]
    def with_unavailable(analyses)
      @identities.to_h { |key| [Support.immutable_copy(key), analyses[key]] }.freeze
    end

    # @rbs @model: untyped
    # @rbs @context_required: bool
    # @rbs @identities: Array[Array[String]]
    # @rbs @time_range: TimeRange?
    # @rbs @analyzer: untyped
    # @rbs @history_preparer: untyped
    # @rbs @version_scope: untyped

    # A root destroyed before the window had no state inside it to read, so
    # only the others take the version after the window as context.
    #: (Array[untyped], Array[untyped], Hash[Array[String], TimeRange]) -> Hash[Array[String], RootVersionPlan]
    def plans(records, destroys, windows)
      start = @time_range&.begin_time
      early = destroys.select { |version| start && version.created_at < start }
                      .map { |version| version.item_id.to_s }
      before, during = records.partition { |record| early.include?(record.id.to_s) }
      plans_for(during, @context_required, windows).merge(plans_for(before, false, windows))
    end

    #: (Array[untyped], bool, Hash[Array[String], TimeRange]) -> Hash[Array[String], RootVersionPlan]
    def plans_for(records, context_required, windows)
      BatchedRootVersions.new(
        records, time_range: @time_range, version_scope: @version_scope,
                 live_endpoints: nil, context_required: context_required, windows: windows
      ).call
    end

    # These records supply identity and model metadata only. Every reported
    # value comes from the batched historical plan; no per-root reify or live
    # lookup is needed to get into the comparison engine.
    #: (Array[untyped]) -> Array[untyped]
    def historical_roots(destroys)
      loader = PreparedVersionStateLoader.new
      destroys.map do |version|
        model = loader.call(version)&.model_class || Endpoint.model_class(version)
        record = model.new
        record[model.primary_key] = version.item_id
        record
      end
    end

    #: () -> Array[untyped]
    def destroy_versions
      destroys = @model.paper_trail.version_class.where(
        item_type: @model.base_class.name, item_id: @identities.map(&:last), event: 'destroy'
      )
      # Oldest first, so each item keeps its latest destroy.
      VersionQuery.chronological(destroys).index_by(&:item_id).values
    end

    #: (Array[untyped], Hash[Array[String], TimeRange]) -> Hash[Symbol, untyped]
    def preparation_range(versions, windows)
      { start_at: TransactionCut.earliest_start(@time_range, windows),
        end_at: [@time_range&.end_time, versions.map(&:created_at).max].compact.max }
    end

    #: (Array[untyped], Hash[Array[String], RootVersionPlan], Hash[Array[String], TimeRange]) -> void
    def prepare(records, selected, windows)
      records.group_by(&:class).each_value do |group|
        versions = group.flat_map do |record|
          selected.fetch(Endpoint.identity(record)).reconstruction_versions
        end
        next if versions.empty?

        @history_preparer.call(group, versions, **preparation_range(versions, windows))
      end
    end
  end
end
