# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects each root's versions for a batched range in a fixed number of
  # queries. Only the range forms that mean the same thing for every root are
  # supported: a shared wall-clock window, or each root's own whole history.
  class BatchedRootVersions
    #: (Array[untyped], time_range: TimeRange?, version_scope: untyped, live_endpoints: Hash[Array[String], untyped]?, context_required: bool, windows: Hash[Array[String], TimeRange]) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      records, time_range:, version_scope:, live_endpoints:, context_required:, windows:
    )
      @records = records
      # Roots whose window moved to a transaction's start, by identity.
      @windows = windows
      # An activity view needs a root to reconstruct from even in a window with
      # no root version, exactly as a single-record activity timeline does.
      @context_required = context_required
      @time_range = time_range
      @version_scope = version_scope
      @live_endpoints = live_endpoints
    end

    # Returns a plan per record identity.
    #: () -> Hash[Array[String], RootVersionPlan]
    def call
      selected = {} #: Hash[Array[String], RootVersionPlan]
      @records.group_by(&:class).each do |model_class, records|
        select_model(model_class, records, selected)
      end
      selected
    end

    private

    # @rbs @records: Array[untyped]
    # @rbs @time_range: TimeRange?
    # @rbs @version_scope: untyped
    # @rbs @live_endpoints: Hash[Array[String], untyped]?
    # @rbs @context_required: bool
    # @rbs @windows: Hash[Array[String], TimeRange]

    #: (untyped, Array[untyped], Hash[Array[String], RootVersionPlan]) -> void
    def select_model(model_class, records, selected)
      in_range, chosen, trailing = model_versions(model_class, records)
      records.each do |record|
        key = Endpoint.identity(record)
        own = own_window(key, record.id.to_s, in_range, trailing)
        selected[key] = versions_for(*own, chosen, live_endpoint(key, record))
      end
    end

    # Moved windows only start and end earlier, so the versions read for the
    # widest of them hold each root's own, and the first left past a moved end.
    #: (Array[String], String, Hash[String, Array[untyped]], Hash[String, untyped]) -> [Array[untyped], untyped]
    def own_window(key, id, in_range, trailing)
      loaded = in_range.fetch(id, [])
      return [loaded, trailing[id]] if @windows.empty?

      # A batch moves windows only when it has one, so this is never nil.
      window = @windows.fetch(key) { @time_range } #: untyped
      own, rest = loaded.partition { |version| window.include?(version.created_at) }
      [own, rest.find { |version| version.created_at >= window.end_time } || trailing[id]]
    end

    #: (untyped, Array[untyped]) -> [Hash[String, Array[untyped]], Set[untyped]?, Hash[String, untyped]]
    def model_versions(model_class, records)
      range = @time_range
      empty = {} #: Hash[String, untyped]
      widest = widest_range(records)
      [
        grouped_versions(model_class, records, widest),
        chosen_version_ids(model_class, records, widest),
        range ? trailing_versions(model_class, records, range) : empty
      ]
    end

    #: (Array[untyped]) -> TimeRange?
    def widest_range(records)
      range = @time_range
      return unless range

      moved = records.filter_map { |record| @windows[Endpoint.identity(record)]&.begin_time }
      start = [range.begin_time, *moved].min
      TimeRange.new(range.exclude_end? ? (start...range.end_time) : (start..range.end_time))
    end

    #: (Array[untyped], untyped, Set[untyped]?, untyped) -> RootVersionPlan
    def versions_for(in_range, after_range, chosen, live_endpoint)
      RootVersionSelection.new(
        in_range: in_range,
        selected: chosen ? in_range.select { |version| chosen.include?(version.id) } : in_range,
        after_range: after_range,
        windowed: !@time_range.nil?,
        context_required: @context_required,
        filtered: !@version_scope.nil?,
        live_endpoint: live_endpoint
      ).call
    end

    # The batch already loaded every root, so closing on current state reuses
    # that rather than reading each record again.
    #: (Array[String], untyped) -> untyped
    def live_endpoint(key, record)
      loaded = @live_endpoints
      return unless loaded

      current = loaded.fetch(key, record)
      current unless current.destroyed?
    end

    # One extra query names the selected mutations without discarding the
    # unfiltered versions the successor lookup still needs.
    #: (untyped, Array[untyped], TimeRange?) -> Set[untyped]?
    def chosen_version_ids(model_class, records, range)
      VersionScopeFilter.new(@version_scope).chosen_ids(range_scope(model_class, records, range))
    end

    #: (untyped, Array[untyped], TimeRange?) -> Hash[String, Array[untyped]]
    def grouped_versions(model_class, records, range)
      VersionQuery.chronological(range_scope(model_class, records, range))
                  .group_by { |version| version.item_id.to_s }
    end

    #: (untyped, Array[untyped], TimeRange?) -> untyped
    def range_scope(model_class, records, range)
      scope = base_scope(model_class, records)
      range ? range.scope(scope) : scope
    end

    #: (untyped, Array[untyped], TimeRange) -> Hash[String, untyped]
    def trailing_versions(model_class, records, range)
      range.first_trailing_versions(base_scope(model_class, records))
    end

    #: (untyped, Array[untyped]) -> untyped
    def base_scope(model_class, records)
      # Active Record reads each record's id.
      VersionQuery.for_items(model_class, records)
    end
  end
end
