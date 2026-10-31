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
    PAGE_SIZE = 250
    private_constant :PAGE_SIZE

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
    # own versions select it.
    #: (untyped, time_range: TimeRange?, limit: Integer, ?historical_filter: untyped, ?max_filter_versions: Integer, ?activity_tree: AssociationTree?) -> void
    def initialize(scope, time_range:, limit:, historical_filter: nil, # rubocop:disable Metrics/ParameterLists
                   max_filter_versions: HistoricalFilter::DEFAULT_VERSION_LIMIT, activity_tree: nil)
      @scope = normalize_scope(scope)
      reject_unversioned!
      @time_range = time_range
      @limit = validate_limit(limit)
      @related = if activity_tree
                   AssociationActivitySelection.new(model, tree: activity_tree,
                                                           time_range: time_range)
                 end
      @historical_filter = unless historical_filter.nil?
                             HistoricalFilter.new(base_class, predicate: historical_filter,
                                                              time_range: time_range, limit: @limit,
                                                              max_versions: max_filter_versions)
                           end
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
    # @rbs @limit: Integer
    # @rbs @historical_filter: untyped
    # @rbs @related: AssociationActivitySelection?

    # Leaves the candidate set in the database. Plucking every root changed in
    # the window would cost memory and a statement proportional to all activity
    # in the window -- not to the relation or `limit:` -- so a report on one
    # record could read every id in a busy table. A subquery keeps the work
    # bounded by what the relation and the deletions actually contain.
    #: (Array[AssociationActivitySelection::Query]) -> Result
    def database_selection(related)
      candidates = [window_versions.select(:item_id)] + related.map(&:relation)
      missing = (missing_ids + related_missing_ids(related)).uniq.sort
      Result.new(
        records: selected_records(candidates),
        unreachable: missing.map { |id| identity(id) }.freeze
      )
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
    # separable. A filter then reads the history of the relation's records
    # only, whose order and page choose among those that match, and of the
    # deleted ones, which no relation can test. Those it lists, as without a
    # filter, but does not count toward `limit:`.
    #: (Array[String]) -> Result
    def plucked_selection(candidates)
      live = ids_in(base_class.unscoped, candidates)
      missing = candidates - live
      if (filter = @historical_filter)
        live = filter.call(ids_in(@scope.except(:order, :limit, :offset), live).uniq)
        missing = filter.call(missing, counted: false)
      end
      Result.new(records: selected_records([live]),
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

    #: (Array[AssociationActivitySelection::Query]) -> Array[String]
    def related_missing_ids(related)
      live = base_class.unscoped.select(primary_key).arel
      related.flat_map { |ids| ids.missing(live) }.map(&:to_s)
    end

    # Changed in the window but without a row, found with an anti-join instead
    # of comparing two plucked lists.
    #: () -> Array[String]
    def missing_ids
      window_versions.where.not(item_id: base_class.unscoped).distinct.pluck(:item_id).map(&:to_s)
    end

    #: () -> untyped
    def window_versions
      relation = VersionQuery.for_items(model)
      range = @time_range
      range ? range.scope(relation) : relation
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
      candidates.each_slice(PAGE_SIZE).flat_map do |slice|
        relation.where(primary_key => slice).pluck(primary_key).map(&:to_s)
      end
    end

    # Deduplicate records rather than adding SQL DISTINCT: an otherwise valid
    # relation may order by joined columns or select a PostgreSQL json column.
    # Read bounded pages until the relation ends or too many unique roots appear.
    # Each candidate source is an id list or a subquery; a record matching any
    # of them is selected.
    #: (Array[untyped]) -> Array[untyped]
    def selected_records(candidates)
      relation = candidate_relation(candidates)
      records = {} #: Hash[untyped, untyped]
      consumed = 0
      loop do
        page = record_page(relation, consumed)
        page.each { |record| records[record.id] ||= record }
        reject_oversized!(records.length)
        break if page.length < PAGE_SIZE

        consumed += page.length
      end
      records.values.freeze
    end

    #: (Array[untyped]) -> untyped
    def candidate_relation(candidates)
      candidates.map do |ids|
        conditions = { primary_key => ids } #: Hash[untyped, untyped]
        ordered_scope.where(conditions)
      end.reduce(:or)
    end

    #: (untyped, Integer) -> Array[untyped]
    def record_page(relation, consumed)
      count = page_limit(consumed)
      return [] if count.zero?

      relation.offset((@scope.offset_value || 0) + consumed).limit(count)
    end

    # Preserve explicit ordering: SQL Server rejects duplicate ORDER BY columns,
    # even when the extra ordering would only have served as a tie-breaker.
    #: () -> untyped
    def ordered_scope
      return @scope unless @scope.order_values.empty?

      @scope.order(primary_key => :asc)
    end

    #: (Integer) -> Integer
    def page_limit(consumed)
      remaining = @scope.limit_value
      [remaining ? remaining - consumed : PAGE_SIZE, PAGE_SIZE].min
    end

    #: (Integer) -> void
    def reject_oversized!(count)
      return unless count > @limit

      raise BatchLimitExceededError,
            "scope: selected more than #{@limit} roots; narrow the window or the " \
            'relation, or raise limit: to the page size you intend to analyze'
    end

    #: (String) -> Array[String]
    def identity(id)
      [item_type, id].freeze
    end

    #: () -> String
    def item_type
      base_class.name
    end

    # A relation delegates class methods to its model, so every mutation here,
    # which drops `.model`, answers the same.
    # mutant:disable
    #: () -> untyped
    def model
      @scope.model
    end

    #: () -> untyped
    def base_class
      model.base_class
    end

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
