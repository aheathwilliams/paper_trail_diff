# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Builds one Analysis per root over a shared range, selecting every root's
  # versions and preparing their association history once for the whole batch
  # rather than once per root.
  class AnalysisBatch
    #: (Array[untyped], time_range: TimeRange?, live_loader: untyped, history_preparer: untyped, analyzer: untyped, ?version_scope: untyped) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      records, time_range:, live_loader:, history_preparer:, analyzer:, version_scope: nil
    )
      @records = records
      @time_range = time_range
      @version_scope = validated_scope(version_scope)
      @live_loader = live_loader
      @history_preparer = history_preparer
      @analyzer = analyzer
    end

    #: () -> Hash[identity, Analysis]
    def call
      records = validated_records
      selected = BatchedRootVersions.new(
        records, time_range: @time_range, version_scope: @version_scope
      ).call
      prepare(records, selected)
      records.to_h do |record|
        key = Endpoint.identity(record)
        plan = selected.fetch(key, RootVersionPlan.empty)
        [Support.immutable_copy(key), analysis_for(record, plan)]
      end.freeze
    end

    private

    # @rbs @records: Array[untyped]
    # @rbs @time_range: TimeRange?
    # @rbs @version_scope: untyped
    # @rbs @live_loader: untyped
    # @rbs @history_preparer: untyped
    # @rbs @analyzer: untyped

    # A filter is a callable that narrows the version relation, so it is checked
    # up front rather than failing partway through a batch.
    #: (untyped) -> untyped
    def validated_scope(scope)
      return scope if scope.nil? || scope.respond_to?(:call)

      raise ConfigurationError, 'version_scope: must respond to call'
    end

    #: () -> Array[untyped]
    def validated_records
      raise ConfigurationError, 'records: must be an array' unless @records.is_a?(Array)

      @records.each { |record| Endpoint.validate!(record) }
      identities = @records.map { |record| Endpoint.identity(record) }
      return @records if identities.uniq.length == identities.length

      raise ConfigurationError, 'records: identities must be unique'
    end

    # Association history is prepared per model class across every selected root
    # version, which is the work that would otherwise repeat for each record.
    # The roots are preloaded first, because preparation reads their current
    # association state as a fallback and would otherwise walk it one root at a
    # time.
    #: (Array[untyped], Hash[Array[String], RootVersionPlan]) -> void
    def prepare(records, selected)
      loaded = @live_loader.call(records)
      records.group_by(&:class).each_value do |grouped|
        versions = grouped.flat_map do |record|
          selected.fetch(Endpoint.identity(record), RootVersionPlan.empty).versions
        end
        next if versions.empty?

        roots = grouped.map { |record| loaded.fetch(Endpoint.identity(record), record) }
        @history_preparer.call(roots, versions)
      end
    end

    # A root with no versions in range has nothing to report, which is an empty
    # result rather than a failed request.
    #: (untyped, RootVersionPlan) -> Analysis
    def analysis_for(record, plan)
      return Analysis.empty if plan.empty?

      @analyzer.call(record, plan)
    end
  end
end
