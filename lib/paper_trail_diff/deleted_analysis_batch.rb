# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Analyzes missing roots together without pretending that they have live rows.
  class DeletedAnalysisBatch
    #: (untyped, identities: Array[Array[String]], time_range: TimeRange?, analyzer: untyped, history_preparer: untyped, ?version_scope: untyped) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      model, identities:, time_range:, analyzer:, history_preparer:, version_scope: nil
    )
      @model = model
      @identities = identities
      @time_range = time_range
      @analyzer = analyzer
      @history_preparer = history_preparer
      @version_scope = version_scope
    end

    #: () -> Hash[Array[String], Analysis?]
    def call
      empty = {} #: Hash[Array[String], Analysis?]
      return empty.freeze if @identities.empty?

      records = historical_roots
      selected = BatchedRootVersions.new(
        records, time_range: @time_range, version_scope: @version_scope
      ).call
      prepare(records, selected)
      analyses = records.to_h do |record|
        key = Endpoint.identity(record)
        plan = selected.fetch(key)
        [key, plan.empty? ? Analysis.empty : @analyzer.call(record, plan)]
      end
      with_unavailable(analyses)
    end

    private

    #: (Hash[Array[String], Analysis]) -> Hash[Array[String], Analysis?]
    def with_unavailable(analyses)
      @identities.to_h { |key| [Support.immutable_copy(key), analyses[key]] }.freeze
    end

    # @rbs @model: untyped
    # @rbs @identities: Array[Array[String]]
    # @rbs @time_range: TimeRange?
    # @rbs @analyzer: untyped
    # @rbs @history_preparer: untyped
    # @rbs @version_scope: untyped

    # These records supply identity and model metadata only. Every reported
    # value comes from the batched historical plan; no per-root reify or live
    # lookup is needed to get into the comparison engine.
    #: () -> Array[untyped]
    def historical_roots
      loader = PreparedVersionStateLoader.new
      destroy_versions.map do |version|
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
      versions = VersionQuery.chronological(destroys)
      versions.group_by { |version| version.item_id.to_s }.values.map do |history|
        Support.chronological_sort(history).last
      end
    end

    #: (Array[untyped]) -> Hash[Symbol, untyped]
    def preparation_range(versions)
      { start_at: @time_range&.begin_time,
        end_at: [@time_range&.end_time, versions.map(&:created_at).max].compact.max }
    end

    #: (Array[untyped], Hash[Array[String], RootVersionPlan]) -> void
    def prepare(records, selected)
      records.group_by(&:class).each_value do |group|
        versions = group.flat_map do |record|
          selected.fetch(Endpoint.identity(record)).reconstruction_versions
        end
        next if versions.empty?

        @history_preparer.call(group, versions, **preparation_range(versions))
      end
    end
  end
end
