# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Applies a historical filter to the candidates of a scoped selection. The
  # filter reads the history of the relation's records only, whose order and
  # page choose among those that match, and of the deleted ones, which no
  # relation can test. Those it lists, as without a filter, but does not
  # count toward `limit:`.
  class FilteredCandidates
    # `ordered` gives the relation that reads candidates as the selected
    # records are read, in a total order.
    #: (untyped, HistoricalFilter, ordered: ^(untyped) -> untyped) -> void
    def initialize(scope, filter, ordered:)
      @scope = scope
      @filter = filter
      @ordered = ordered
    end

    # The live candidates the filter matches, and the deleted ones.
    #: (Array[String], Array[String]) -> [Array[String], Array[String]]
    def call(live, missing)
      page = self.page
      members = page ? ordered_members(live) : members(live)
      [@filter.call(members, page: page), @filter.call(missing, counted: false)]
    end

    private

    # @rbs @scope: untyped
    # @rbs @filter: HistoricalFilter
    # @rbs @ordered: ^(untyped) -> untyped

    # The matches the relation's own offset and limit skip and take, or nil
    # without a limit, when every match is selected. The filter reads
    # candidates in the relation's order and stops when the page is full, so
    # a page costs the history it reads rather than every match's. A grouped
    # relation pages its groups, which only all of its matches decide.
    #: () -> [Integer, Integer]?
    def page
      size = Support.limit(@scope)
      [Support.offset(@scope), size] if size && @scope.group_values.empty?
    end

    # The relation's records among the candidates, in its order, without its
    # page. A relation that selects or deduplicates its own columns may order
    # by them, so its records are loaded instead of their keys alone.
    #: (Array[String]) -> Array[String]
    def ordered_members(ids)
      plain = @scope.select_values.empty? && !@scope.distinct_value
      CandidateTable.with(@scope.model.base_class, ids) do |source|
        relation = @ordered.call(source).except(:limit, :offset)
        keys = plain ? relation.pluck(primary_key) : relation.map(&:id)
        keys.map(&:to_s).uniq
      end
    end

    # The candidates the relation's conditions accept. A grouped relation's
    # rows are groups, which a condition on one record cannot decide, and its
    # aggregates read every candidate at once, so it keeps them all: the
    # filter reads each, and the relation groups those that match.
    #: (Array[String]) -> Array[String]
    def members(ids)
      return ids unless @scope.group_values.empty?

      relation = @scope.except(:order, :limit, :offset)
      ids.each_slice(Support::IDS_PER_STATEMENT).flat_map do |slice|
        relation.where(primary_key => slice).pluck(primary_key).map(&:to_s)
      end.uniq
    end

    #: () -> untyped
    def primary_key
      @scope.model.primary_key
    end
  end
end
