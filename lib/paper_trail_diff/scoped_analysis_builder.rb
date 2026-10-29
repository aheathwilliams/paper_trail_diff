# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects both populations and checks their shared ceiling before analysis.
  class ScopedAnalysisBuilder
    #: (untyped, limit: Integer?, within: untyped, historical_filter: untyped, max_filter_versions: Integer, include_deleted: bool, analyzer: untyped, deleted_analyzer: untyped, ?activity_tree: AssociationTree?) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      scope, limit:, within:, historical_filter:, max_filter_versions:, include_deleted:,
      analyzer:, deleted_analyzer:, activity_tree: nil
    )
      raise ConfigurationError, 'limit: is required when selecting roots by scope' if limit.nil?
      unless [true, false].include?(include_deleted)
        raise ConfigurationError, 'include_deleted: must be true or false'
      end

      @selection = ScopedRootSelection.new(
        scope, limit: limit, time_range: within.nil? ? nil : TimeRange.new(within),
               historical_filter: historical_filter, max_filter_versions: max_filter_versions,
               activity_tree: activity_tree
      )
      @limit = limit
      @include_deleted = include_deleted
      @analyzer = analyzer
      @deleted_analyzer = deleted_analyzer
    end

    #: () -> ScopedAnalysis
    def call
      selection = @selection.call
      if @include_deleted && selection.records.length + selection.unreachable.length > @limit
        raise BatchLimitExceededError, 'include_deleted: live and missing roots exceed limit:'
      end

      ScopedAnalysis.new(
        analyses: @analyzer.call(selection.records), roots: selection.records,
        unreachable: selection.unreachable,
        deleted: @include_deleted ? @deleted_analyzer.call(selection.unreachable) : {}
      )
    end

    # @rbs @selection: ScopedRootSelection
    # @rbs @limit: Integer
    # @rbs @include_deleted: bool
    # @rbs @analyzer: untyped
    # @rbs @deleted_analyzer: untyped
  end
end
