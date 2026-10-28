# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects each root's versions for a batched range in a fixed number of
  # queries. Only the range forms that mean the same thing for every root are
  # supported: a shared wall-clock window, or each root's own whole history.
  class BatchedRootVersions
    #: (Array[untyped], time_range: TimeRange?, ?version_scope: untyped, ?live_endpoints: Hash[Array[String], untyped]?, ?context_required: bool) -> void
    def initialize(records, time_range:, version_scope: nil, live_endpoints: nil,
                   context_required: false)
      @records = records
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
      return {} if @records.empty?

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

    #: (untyped, Array[untyped], Hash[Array[String], RootVersionPlan]) -> void
    def select_model(model_class, records, selected)
      ids = records.map(&:id)
      in_range, chosen, trailing = model_versions(model_class, ids)
      records.each do |record|
        key = identity(model_class, record.id)
        selected[key] = versions_for(
          in_range.fetch(record.id.to_s, []), chosen, trailing[record.id.to_s],
          live_endpoint(key, record)
        )
      end
    end

    #: (untyped, Array[untyped]) -> [Hash[String, Array[untyped]], Set[untyped]?, Hash[String, untyped]]
    def model_versions(model_class, ids)
      range = @time_range
      empty = {} #: Hash[String, untyped]
      [
        grouped_versions(model_class, ids, range),
        chosen_version_ids(model_class, ids, range),
        range ? trailing_versions(model_class, ids, range) : empty
      ]
    end

    #: (Array[untyped], Set[untyped]?, untyped, untyped) -> RootVersionPlan
    def versions_for(in_range, chosen, after_range, live_endpoint)
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
    def chosen_version_ids(model_class, ids, range)
      scope = @version_scope
      return unless scope

      # A narrowed relation is the expected return. Active Support also gives
      # `pluck` to plain enumerables, so an array of versions works too.
      filtered = scope.call(range_scope(model_class, ids, range))
      Set.new(filtered.pluck(:id))
    end

    #: (untyped, Array[untyped], TimeRange?) -> Hash[String, Array[untyped]]
    def grouped_versions(model_class, ids, range)
      ordered(range_scope(model_class, ids, range)).group_by { |version| version.item_id.to_s }
    end

    #: (untyped, Array[untyped], TimeRange?) -> untyped
    def range_scope(model_class, ids, range)
      scope = base_scope(model_class, ids)
      range ? range.scope(scope) : scope
    end

    #: (untyped, Array[untyped], TimeRange) -> Hash[String, untyped]
    def trailing_versions(model_class, ids, range)
      range.first_trailing_versions(base_scope(model_class, ids))
    end

    #: (untyped, Array[untyped]) -> untyped
    def base_scope(model_class, ids)
      model_class.paper_trail.version_class.where(
        item_type: model_class.base_class.name.to_s,
        item_id: ids
      )
    end

    #: (untyped) -> Array[untyped]
    def ordered(relation)
      relation.reorder(created_at: :asc, id: :asc).to_a
    end

    #: (untyped, untyped) -> Array[String]
    def identity(model_class, id)
      [model_class.base_class.name.to_s, id.to_s]
    end
  end
end
