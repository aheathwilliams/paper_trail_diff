# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects both populations and checks their shared ceiling before analysis.
  class ScopedAnalysisBuilder
    #: (untyped, limit: Integer?, within: untyped, historical_filter: untyped, max_filter_versions: Integer, include_deleted: bool, analyzer: untyped, deleted_analyzer: untyped, ?activity_tree: AssociationTree?, ?version_scope: untyped) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      scope, limit:, within:, historical_filter:, max_filter_versions:, include_deleted:,
      analyzer:, deleted_analyzer:, activity_tree: nil, version_scope: nil
    )
      raise ConfigurationError, 'limit: is required when selecting roots by scope' if limit.nil?
      unless [true, false].include?(include_deleted)
        raise ConfigurationError, 'include_deleted: must be true or false'
      end

      @selection = ScopedRootSelection.new(
        scope, limit: limit, time_range: within.nil? ? nil : TimeRange.new(within),
               historical_filter: historical_filter, max_filter_versions: max_filter_versions,
               activity_tree: activity_tree, version_scope: version_scope
      )
      @deleted_filter = deleted_filter(scope, include_deleted)
      @include_deleted = include_deleted
      @limit = limit
      @analyzer = analyzer
      @deleted_analyzer = deleted_analyzer
    end

    #: () -> ScopedAnalysis
    def call
      selection = @selection.call
      unreachable = @deleted_filter&.call(selection.unreachable) || selection.unreachable
      return analysis(selection, unreachable, {}) unless @include_deleted

      if selection.records.length + unreachable.length > @limit
        raise BatchLimitExceededError, 'include_deleted: live and missing roots exceed limit:'
      end

      analysis(selection, unreachable, @deleted_analyzer.call(unreachable))
    end

    private

    # Without the option, the deleted roots are still tested when the
    # relation can be read, so that another selection's are not listed.
    #: (untyped, bool) -> DeletedRootFilter?
    def deleted_filter(scope, include_deleted)
      return DeletedRootFilter.new(scope.all) if include_deleted

      DeletedRootFilter.readable(scope.all)
    end

    #: (ScopedRootSelection::Result, Array[Array[String]], Hash[Array[String], Analysis?]) -> ScopedAnalysis
    def analysis(selection, unreachable, deleted)
      ScopedAnalysis.new(analyses: @analyzer.call(selection.records), roots: selection.records,
                         unreachable: unreachable, deleted: deleted)
    end

    # @rbs @selection: ScopedRootSelection
    # @rbs @deleted_filter: DeletedRootFilter?
    # @rbs @include_deleted: bool
    # @rbs @limit: Integer
    # @rbs @analyzer: untyped
    # @rbs @deleted_analyzer: untyped
  end
end
