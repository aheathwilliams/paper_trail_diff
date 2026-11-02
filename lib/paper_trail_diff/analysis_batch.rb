# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Builds one Analysis per root over a shared range, selecting every root's
  # versions and preparing their association history once for the whole batch
  # rather than once per root.
  class AnalysisBatch
    #: (Array[untyped], time_range: TimeRange?, live_loader: untyped, history_preparer: untyped, analyzer: untyped, ?version_scope: untyped, ?context_required: bool) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      records, time_range:, live_loader:, history_preparer:, analyzer:, version_scope: nil,
      context_required: false
    )
      @records = records
      @context_required = context_required
      @time_range = time_range
      # Checked up front rather than failing partway through a batch.
      @version_scope = VersionScopeFilter.validated(version_scope)
      @live_loader = live_loader
      @history_preparer = history_preparer
      @analyzer = analyzer
    end

    #: () -> Hash[identity, Analysis]
    def call
      records = validated_records
      loaded = @live_loader.call(records)
      windows = TransactionCut.batch_windows(records, @time_range)
      # Activity on associations both takes a context and replays whole plans.
      plans = BatchedRootVersions.new(
        records, time_range: @time_range, version_scope: @version_scope,
                 live_endpoints: loaded, context_required: @context_required,
                 whole: @context_required, windows: windows
      ).call
      BatchedRootAnalyses.new(
        time_range: @time_range, windows: windows, history_preparer: @history_preparer,
        analyzer: @analyzer
      ).call(records, plans, loaded: loaded).freeze
    end

    private

    # @rbs @records: Array[untyped]
    # @rbs @time_range: TimeRange?
    # @rbs @version_scope: untyped
    # @rbs @context_required: bool
    # @rbs @live_loader: untyped
    # @rbs @history_preparer: untyped
    # @rbs @analyzer: untyped

    #: () -> Array[untyped]
    def validated_records
      raise ConfigurationError, 'records: must be an array' unless @records.is_a?(Array)

      @records.each do |record|
        Endpoint.validate_root!(record)
        Endpoint.validate!(record)
      end
      identities = @records.map { |record| Endpoint.identity(record) }
      return @records if identities.uniq.length == identities.length

      raise ConfigurationError, 'records: identities must be unique'
    end
  end
end
