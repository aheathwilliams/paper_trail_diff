# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Chooses the roots a batch will analyze from a relation instead of from an
  # array the caller assembled, so a reporting page does not reimplement the
  # root selection this gem already performs.
  #
  # Two populations are deliberately kept apart, because conflating them would
  # make the report wrong in a way nothing announces:
  #
  # - A root whose live row does not satisfy the relation is filtered out. That
  #   is what the caller asked for, and it needs no reporting.
  # - A root whose live row is gone cannot be filtered at all. The relation's
  #   conditions read the live table, and a destroyed root has nothing there to
  #   read -- even though its history is intact, and the state it held when it
  #   was destroyed may well have satisfied those conditions. Reifying every
  #   candidate to find out would cost the batched query plan this class exists
  #   to provide.
  #
  # So the second population is returned by name rather than dropped. A caller
  # that does not care can ignore it; one auditing deletions is told where to
  # look instead of silently coming up short.
  #
  # Note that a relation filters on current state, not on state during the
  # window. `where(status: 'published')` selects what is published now, which is
  # not the same set as what was published while the window was open.
  class ScopedRootSelection
    MIN_PAGE_SIZE = 250
    MAX_PAGE_SIZE = 2_000
    private_constant :MIN_PAGE_SIZE, :MAX_PAGE_SIZE

    # A plain class rather than Data.define, which arrived in Ruby 3.2 while this
    # gem supports 3.1.
    class Result
      attr_reader :records #: Array[untyped]
      attr_reader :unreachable #: Array[Array[String]]

      #: (records: Array[untyped], unreachable: Array[Array[String]]) -> void
      def initialize(records:, unreachable:)
        @records = records
        @unreachable = unreachable
        freeze
      end
    end

    # `activity_tree` names the association paths whose changes also select a
    # root, as an activity analysis reports them. Without one, only a root's
    # own versions select it. `version_scope` narrows which of either count,
    # as it narrows which are reported.
    #
    # A window selects by the versions saved in it. A transaction that saves
    # there and ends after it is reported in a later window (see
    # TransactionEnds), so a root can be selected with nothing to report. One
    # open at the window's start is reported in it, though it may have saved
    # the root's tree only before it, so with associations the roots are
    # selected from where the earliest such transaction began.
    #: (untyped, time_range: TimeRange?, limit: Integer, ?historical_filter: untyped, ?max_filter_versions: Integer, ?activity_tree: AssociationTree?, ?version_scope: untyped) -> void
    def initialize(scope, time_range:, limit:, historical_filter: nil, # rubocop:disable Metrics/ParameterLists
                   max_filter_versions: HistoricalFilter::DEFAULT_VERSION_LIMIT, activity_tree: nil,
                   version_scope: nil)
      @scope = normalize_scope(scope)
      reject_unversioned!
      @time_range = time_range
      @version_scope = VersionScopeFilter.validated(version_scope)
      @limit = validate_limit(limit)
      @selecting = AssociationActivitySelection.window(model, activity_tree, time_range)
      @related = activity_tree && AssociationActivitySelection.new(
        model, tree: activity_tree, time_range: @selecting, version_scope: @version_scope
      )
      @historical_filter = historical_filter_for(historical_filter, max_filter_versions)
    end

    #: () -> Result
    def call
      related = @related&.call || []
      queries = subqueries(related)
      return database_selection(queries) if queries

      plucked_selection(versioned_ids | AssociationActivitySelection.values(related).map(&:to_s))
    end

    private

    # @rbs @scope: untyped
    # @rbs @time_range: TimeRange?
    # @rbs @selecting: TimeRange?
    # @rbs @limit: Integer
    # @rbs @historical_filter: FilteredCandidates?
    # @rbs @related: AssociationActivitySelection?
    # @rbs @version_scope: untyped

    # Leaves the candidate set in the database. Plucking every root changed in
    # the window would cost memory and a statement proportional to all activity
    # in the window -- not to the relation or `limit:` -- so a report on one
    # record could read every id in a busy table. A subquery keeps the work
    # bounded by what the relation and the deletions actually contain.
    #: (Array[AssociationActivitySelection::Query]) -> Result
    def database_selection(related)
      sources = [changed_roots, *related]
      missing = sources.flat_map { |ids| ids.missing(base_class) }.map(&:to_s).uniq.sort
      Result.new(
        records: selected_records(sources.map(&:relation)),
        unreachable: missing.map { |id| identity(id) }.freeze
      )
    end

    # The roots with a version of their own in the window. Those without a
    # row are found in the database too (see Query#missing), not by comparing
    # two plucked lists. Only the related queries' types are compared, so
    # this one names none.
    #: () -> AssociationActivitySelection::Query
    def changed_roots
      AssociationActivitySelection::Query.new(window_versions, version_class.arel_table[:item_id],
                                              nil)
    end

    # Comparing in SQL needs every subquery's column to share the key's type.
    #: (Array[AssociationActivitySelection::source]) -> Array[AssociationActivitySelection::Query]?
    def subqueries(related)
      return unless @historical_filter.nil? && comparable_keys?

      queries = related.grep(AssociationActivitySelection::Query) #: Array[AssociationActivitySelection::Query]
      matching = queries.select { |ids| ids.type == key_type }
      matching if matching.length == related.length
    end

    # Which candidates still have a row is asked without the relation's
    # conditions, so that "filtered out" and "no longer exists" stay
    # separable. A filter then keeps those it matches (FilteredCandidates).
    #: (Array[String]) -> Result
    def plucked_selection(candidates)
      live = ids_in(base_class.unscoped, candidates)
      missing = candidates - live
      filter = @historical_filter
      live, missing = filter.call(live, missing) if filter
      Result.new(records: CandidateTable.with(base_class, live) { |ids| selected_records([ids]) },
                 unreachable: missing.sort.map { |id| identity(id) }.freeze)
    end

    # Comparing the two columns in SQL needs them to share a type: PostgreSQL
    # rejects an integer key against a string item_id outright. A composite
    # key names no single attribute, so it has no type and never matches.
    #: () -> bool
    def comparable_keys?
      version_class.type_for_attribute('item_id').type == key_type
    end

    #: () -> Symbol?
    def key_type
      base_class.type_for_attribute(primary_key).type
    end

    # Only the versions `version_scope` keeps select a root: one whose versions
    # in the window it drops would have nothing to report.
    #: () -> untyped
    def window_versions
      range = @selecting
      relation = VersionQuery.for_model(model)
      relation = range.scope(relation) if range
      @version_scope ? @version_scope.call(relation) : relation
    end

    #: (untyped, Integer) -> FilteredCandidates?
    def historical_filter_for(predicate, max_versions)
      return if predicate.nil?

      filter = HistoricalFilter.new(base_class, predicate: predicate, time_range: @time_range,
                                                limit: @limit, max_versions: max_versions)
      FilteredCandidates.new(@scope, filter, ordered: ->(ids) { candidate_relation(ids) })
    end

    # Accepts a model class as readily as a relation: `Article` and
    # `Article.where(...)` both name a population, and `all` is what makes them
    # the same kind of thing.
    #: (untyped) -> untyped
    def normalize_scope(scope)
      unless scope.respond_to?(:all) && scope.respond_to?(:where)
        raise ConfigurationError, 'scope: must be an ActiveRecord relation or model class'
      end

      scope.all
    end

    #: () -> void
    def reject_unversioned!
      return if Support.versioned?(model)

      raise UnversionedAssociationError,
            "scope: #{model} is not versioned, so it has no history to select from"
    end

    # No Integer subclass has instances, so this is `is_a?` by another name.
    #: (Integer) -> Integer
    def validate_limit(limit)
      return limit if limit.instance_of?(Integer) && limit.positive?

      raise ConfigurationError, 'limit: must be a positive Integer'
    end

    # Every root whose history moved inside the window, destroyed ones included.
    # This is the gem's own notion of "which roots changed", answered from the
    # version table alone so that it does not depend on rows still existing.
    #: () -> Array[String]
    def versioned_ids
      window_versions.distinct.pluck(:item_id).map(&:to_s)
    end

    #: (untyped, Array[String]) -> Array[String]
    def ids_in(relation, candidates)
      candidates.each_slice(Support::IDS_PER_STATEMENT).flat_map do |slice|
        relation.where(primary_key => slice).pluck(primary_key).map(&:to_s)
      end
    end

    # Deduplicate records rather than adding SQL DISTINCT: an otherwise valid
    # relation may order by joined columns or select a PostgreSQL json column.
    # Read bounded pages until the relation ends or too many unique roots appear.
    # Each candidate source is an id list or a subquery, such as a
    # CandidateTable's; a record matching any of them is selected.
    #: (Array[untyped]) -> Array[untyped]
    def selected_records(candidates)
      relation = candidate_relation(*candidates)
      records = {} #: Hash[untyped, untyped]
      consumed = 0
      loop do
        page = record_page(relation, consumed)
        page.each { |record| records[record.id] ||= record }
        reject_oversized!(records.length)
        break if page.length < page_size

        consumed += page.length
      end
      records.values.freeze
    end

    # Pages are read by offset, so under a total order.
    #: (*untyped) -> untyped
    def candidate_relation(*candidates)
      candidates.map do |ids|
        conditions = { primary_key => ids } #: Hash[untyped, untyped]
        TotalOrder.apply(@scope).where(conditions)
      end.reduce(:or)
    end

    #: (untyped, Integer) -> Array[untyped]
    def record_page(relation, consumed)
      count = page_limit(consumed)
      return [] if count.zero?

      relation.offset(Support.offset(@scope) + consumed).limit(count)
    end

    #: (Integer) -> Integer
    def page_limit(consumed)
      remaining = Support.limit(@scope)
      [remaining ? remaining - consumed : page_size, page_size].min
    end

    # Every page repeats the candidates, a list of ids or the subqueries that
    # find them, and skips the rows read before it, so pages much smaller than
    # the selection read the candidates many times over. More roots than
    # `limit:` raise, so a page never needs more than one past it. A page
    # holds at least 250 rows, for a relation whose joins repeat a record,
    # and at most 2,000: SQL Server compiles a statement with its ids written
    # in, and one that listed 20,000 and returned them all outlasted the
    # adapter's default timeout of 5 seconds. There a long list is now read
    # from a CandidateTable, but other databases still repeat it.
    #: () -> Integer
    def page_size
      (@limit + 1).clamp(MIN_PAGE_SIZE, MAX_PAGE_SIZE)
    end

    #: (Integer) -> void
    def reject_oversized!(count)
      return unless count > @limit

      raise BatchLimitExceededError,
            "scope: selected more than #{@limit} roots; narrow the window or the " \
            'relation, or raise limit: to the page size you intend to analyze'
    end

    # Keyed as Endpoint.identity keys the record, which the analyses use.
    #: (String) -> Array[String]
    def identity(id)
      Support.record_identity(model, id).freeze
    end

    # A relation delegates class methods to its model, so every mutation here,
    # which drops `.model`, answers the same.
    # mutant:disable
    #: () -> untyped
    def model
      @scope.model
    end

    #: () -> untyped
    def base_class = model.base_class

    #: () -> untyped
    def primary_key
      model.primary_key
    end

    #: () -> untyped
    def version_class
      model.paper_trail.version_class
    end
  end
end
