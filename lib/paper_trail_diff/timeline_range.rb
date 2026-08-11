# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Chooses explicit-version or wall-clock selection for one timeline request.
  class TimelineRange
    BOUNDARY_SYMBOLS = %i[first last].freeze

    attr_reader :from #: untyped
    attr_reader :to #: untyped
    attr_reader :time_range #: TimeRange?

    #: (untyped, from: untyped, to: untyped, within: untyped, ?versions: Array[untyped]?, ?version_scope: untyped, ?plan: RootVersionPlan?, ?live_endpoint: untyped) -> void
    def initialize(record, from:, to:, within:, versions: nil, version_scope: nil, plan: nil, live_endpoint: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      @record = record
      @plan = plan
      @live_endpoint = live_endpoint
      @versions = (plan ? plan.versions : versions)&.freeze
      @version_scope = version_scope
      @requested_from = from
      @requested_to = to
      @time_range = build_time_range(within)
      validate_mode!
      @from = resolve(from)
      @to = resolve(to)
      freeze
    end

    # A record with no versions has no first or last boundary to resolve, which
    # is an empty history rather than a bad request.
    #: () -> bool
    def unresolved?
      (symbolic?(@requested_from) && @from.nil?) || (symbolic?(@requested_to) && @to.nil?)
    end

    # A batch may have selected these versions already, in which case reselecting
    # them per record would undo the batching.
    # The plan says which pairs of versions become steps, which a filter can
    # make different from adjacent pairs of the selected versions.
    #: (?context_required: bool) -> RootVersionPlan
    def select_plan(context_required: false)
      preselected = @plan
      return preselected if preselected

      range = time_range
      if range
        return TimeVersionRange.new(
          @record, time_range: range, version_scope: @version_scope,
                   live_endpoint: @live_endpoint
        ).select_plan(context_required: context_required)
      end
      return RootVersionPlan.empty if unresolved?

      VersionRange.new(
        @record, from: @from, to: @to, version_scope: @version_scope
      ).select_plan_for_range
    end

    #: (?context_required: bool) -> Array[untyped]
    def select(context_required: false)
      preselected = @versions
      return preselected if preselected

      range = time_range
      if range
        return TimeVersionRange.new(
          @record, time_range: range, version_scope: @version_scope
        ).select(context_required: context_required)
      end
      return empty_versions if unresolved?

      VersionRange.new(@record, from: @from, to: @to, version_scope: @version_scope).select
    end

    #: () -> bool
    def time?
      !time_range.nil?
    end

    #: () -> Time?
    def begin_time
      time_range&.begin_time
    end

    #: (untyped) -> bool
    def include?(version)
      range = time_range
      !range || range.include?(version.created_at)
    end

    private

    # @rbs @record: untyped
    # @rbs @versions: Array[untyped]?
    # @rbs @plan: RootVersionPlan?
    # @rbs @version_scope: untyped
    # @rbs @live_endpoint: untyped
    # @rbs @requested_from: untyped
    # @rbs @requested_to: untyped
    # @rbs @from: untyped
    # @rbs @to: untyped

    #: () -> Array[untyped]
    def empty_versions
      versions = [] #: Array[untyped]
      versions.freeze
    end

    #: (untyped) -> bool
    def symbolic?(boundary)
      boundary.is_a?(Symbol)
    end

    # Resolving `:first` and `:last` here keeps callers from depending on the
    # order PaperTrail happens to give its versions association, which a caller
    # is also free to reorder.
    #: (untyped) -> untyped
    def resolve(boundary)
      return boundary unless symbolic?(boundary)

      unless BOUNDARY_SYMBOLS.include?(boundary)
        raise InvalidTimelineRangeError,
              "unsupported boundary: #{boundary.inspect}; use :first, :last, a version, or a record"
      end

      boundary == :first ? ordered_versions.first : ordered_versions.last
    end

    #: () -> untyped
    def ordered_versions
      versions_relation.reorder(created_at: :asc, id: :asc)
    end

    #: () -> untyped
    def versions_relation
      @record.public_send(@record.class.versions_association_name)
    rescue NoMethodError => e
      message = 'record does not expose a PaperTrail version history'
      raise InvalidTimelineRangeError, message, cause: e
    end

    #: (untyped) -> TimeRange?
    def build_time_range(within)
      TimeRange.new(within) unless within.nil?
    end

    #: () -> void
    def validate_mode!
      if time?
        return if @requested_from.nil? && @requested_to.nil?

        raise InvalidTimelineRangeError, '`within` cannot be combined with `from` or `to`'
      end
      return unless @requested_from.nil? || @requested_to.nil?

      raise InvalidTimelineRangeError, 'provide both `from` and `to`, or provide `within`'
    end
  end
end
