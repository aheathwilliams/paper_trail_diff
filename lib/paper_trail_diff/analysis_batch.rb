# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Builds one Analysis per root over a shared range, selecting every root's
  # versions and preparing their association history once for the whole batch
  # rather than once per root.
  class AnalysisBatch
    #: (Array[untyped], time_range: TimeRange?, live_loader: untyped, history_preparer: untyped, analyzer: untyped) -> void
    def initialize(records, time_range:, live_loader:, history_preparer:, analyzer:)
      @records = records
      @time_range = time_range
      @live_loader = live_loader
      @history_preparer = history_preparer
      @analyzer = analyzer
    end

    #: () -> Hash[identity, Analysis]
    def call
      records = validated_records
      selected = BatchedRootVersions.new(records, time_range: @time_range).call
      prepare(records, selected)
      records.to_h do |record|
        key = Endpoint.identity(record)
        [Support.immutable_copy(key), analysis_for(record, selected.fetch(key, []))]
      end.freeze
    end

    private

    # @rbs @records: Array[untyped]
    # @rbs @time_range: TimeRange?
    # @rbs @live_loader: untyped
    # @rbs @history_preparer: untyped
    # @rbs @analyzer: untyped

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
    #: (Array[untyped], Hash[Array[String], Array[untyped]]) -> void
    def prepare(records, selected)
      loaded = @live_loader.call(records)
      records.group_by(&:class).each_value do |grouped|
        versions = grouped.flat_map { |record| selected.fetch(Endpoint.identity(record), []) }
        next if versions.empty?

        roots = grouped.map { |record| loaded.fetch(Endpoint.identity(record), record) }
        @history_preparer.call(roots, versions)
      end
    end

    # A root with no versions in range has nothing to report, which is an empty
    # result rather than a failed request.
    #: (untyped, Array[untyped]) -> Analysis
    def analysis_for(record, versions)
      return Analysis.empty if versions.empty?

      @analyzer.call(record, versions)
    end
  end
end
