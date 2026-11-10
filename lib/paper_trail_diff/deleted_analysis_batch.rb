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
      analyses = BatchedRootAnalyses.new(
        time_range: @time_range, planner: ->(roots, range) { plans(roots, destroys, range) },
        history_preparer: @history_preparer, analyzer: @analyzer
      ).call(records)
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

    # A root destroyed before the range had no state inside it to read, so
    # only the others take the version after the range as context. Every
    # root replays the whole of its range for activity on associations. The
    # range is the window, or the window widened to how far its transactions
    # reach, which can hold a destroy that one of them saved.
    #: (Array[untyped], Array[untyped], TimeRange?) -> Hash[Array[String], RootVersionPlan]
    def plans(records, destroys, range)
      start = range&.begin_time
      early = destroys.select { |version| start && version.created_at < start }
                      .map { |version| version.item_id.to_s }
      before, during = records.partition { |record| early.include?(record.id.to_s) }
      plans_for(during, @context_required, range)
        .merge(plans_for(before, false, reaching(before, range)))
    end

    # The range for roots destroyed before it: widened to where the
    # transactions open at its start began, when activity on associations is
    # asked for, since one of them may have saved the destroy and gone on to
    # save the root's tree inside the range, which then reports both. No
    # version of such a root is in the range to find the transaction by.
    #: (Array[untyped], TimeRange?) -> TimeRange?
    def reaching(records, range)
      return range unless range && @context_required && records.any?

      none = [] #: Array[untyped]
      reach = @history_preparer.call(records, none, start_at: range.begin_time,
                                                    end_at: range.end_time)
      reach ? range.widened(reach.first, nil) : range
    end

    #: (Array[untyped], bool, TimeRange?) -> Hash[Array[String], RootVersionPlan]
    def plans_for(records, context_required, range)
      BatchedRootVersions.new(
        records, time_range: range, version_scope: @version_scope,
                 live_endpoints: nil, context_required: context_required,
                 whole: @context_required
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

    # Each statement reads the destroys of 500 records.
    #: () -> Array[untyped]
    def destroy_versions
      @identities.map(&:last).each_slice(Support::IDS_PER_STATEMENT).flat_map do |ids|
        destroys = VersionQuery.for_items(@model, ids).where(event: 'destroy')
        # Oldest first, so each item keeps its latest destroy.
        VersionQuery.chronological(destroys).index_by(&:item_id).values
      end
    end
  end
end
