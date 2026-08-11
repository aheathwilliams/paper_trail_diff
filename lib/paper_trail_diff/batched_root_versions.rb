# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects each root's versions for a batched range in a fixed number of
  # queries. Only the range forms that mean the same thing for every root are
  # supported: a shared wall-clock window, or each root's own whole history.
  class BatchedRootVersions
    #: (Array[untyped], time_range: TimeRange?, ?version_scope: untyped) -> void
    def initialize(records, time_range:, version_scope: nil)
      @records = records
      @time_range = time_range
      @version_scope = version_scope
    end

    # Returns root versions per record identity, in chronological order.
    #: () -> Hash[Array[String], Array[untyped]]
    def call
      return {} if @records.empty?

      selected = {} #: Hash[Array[String], Array[untyped]]
      @records.group_by(&:class).each do |model_class, records|
        select_model(model_class, records, selected)
      end
      selected
    end

    private

    # @rbs @records: Array[untyped]
    # @rbs @time_range: TimeRange?
    # @rbs @version_scope: untyped

    #: (untyped, Array[untyped], Hash[Array[String], Array[untyped]]) -> void
    def select_model(model_class, records, selected)
      ids = records.map(&:id)
      in_range, chosen, trailing = model_versions(model_class, ids)
      records.each do |record|
        key = identity(model_class, record.id)
        selected[key] = versions_for(
          in_range.fetch(record.id.to_s, []), chosen, trailing[record.id.to_s]
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

    # The selected mutations, plus whichever unfiltered version follows the last
    # of them. That successor is reconstruction context rather than a selected
    # mutation, so a filter must never remove it: without it the final selected
    # change cannot be revealed at all. A range closing on the root's own
    # destruction needs no successor, because none can exist.
    #: (Array[untyped], Set[untyped]?, untyped) -> Array[untyped]
    def versions_for(in_range, chosen, after_range)
      selected = chosen ? in_range.select { |version| chosen.include?(version.id) } : in_range
      return selected.freeze if selected.empty?

      successor = successor_for(in_range, selected.last, after_range)
      return (selected + [successor]).freeze if successor
      return selected.freeze if @time_range.nil? || terminal_destroy?(selected)

      raise IncompleteTimeRangeError,
            'time range requires a later root version to reconstruct its final change'
    end

    # A filtered-out version still inside the range is the state the last
    # selected change produced, so it is preferred over anything after the range.
    #: (Array[untyped], untyped, untyped) -> untyped
    def successor_for(in_range, last_selected, after_range)
      within = in_range.find do |version|
        Support.compare_versions(last_selected, version).negative?
      end
      within || after_range
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

    #: (Array[untyped]) -> bool
    def terminal_destroy?(versions)
      versions.last&.event.to_s == 'destroy'
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

    # One row per root: the earliest version after the window, found without a
    # window function so the query stays portable.
    #: (untyped, Array[untyped], TimeRange) -> Hash[String, untyped]
    def trailing_versions(model_class, ids, range)
      table = model_class.paper_trail.version_class.arel_table
      relation = range.trailing_scope(base_scope(model_class, ids))
      ordered(relation.where(no_earlier_trailing(table, range)))
        .to_h { |version| [version.item_id.to_s, version] }
    end

    #: (untyped, TimeRange) -> untyped
    def no_earlier_trailing(table, range)
      arel = Object.const_get(:Arel) #: untyped
      later = table.alias('paper_trail_diff_later_roots')
      arel.const_get(:SelectManager).new
          .from(later)
          .project(arel.sql('1'))
          .where(preceding(table, later, range))
          .exists
          .not
    end

    # Mirrors the window's own end handling, so a version sitting exactly on an
    # inclusive boundary stays inside the window instead of masking the trailing
    # version that follows it.
    #: (untyped, untyped, TimeRange) -> untyped
    def preceding(table, later, range)
      same_item = later[:item_type].eq(table[:item_type])
                                   .and(later[:item_id].eq(table[:item_id]))
      same_item.and(after_window(later, range)).and(later[:created_at].lt(table[:created_at]))
    end

    #: (untyped, TimeRange) -> untyped
    def after_window(later, range)
      return later[:created_at].gteq(range.end_time) if range.exclude_end?

      later[:created_at].gt(range.end_time)
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
