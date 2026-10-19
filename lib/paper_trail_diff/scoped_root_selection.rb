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

    #: (untyped, time_range: TimeRange?, limit: Integer, ?historical_filter: untyped, ?max_filter_versions: Integer) -> void
    def initialize(scope, time_range:, limit:, historical_filter: nil,
                   max_filter_versions: HistoricalFilter::DEFAULT_VERSION_LIMIT)
      @scope = normalize_scope(scope)
      @time_range = time_range
      @limit = validate_limit(limit)
      @historical_filter = unless historical_filter.nil?
                             HistoricalFilter.new(base_class, predicate: historical_filter,
                                                              time_range: time_range, limit: @limit,
                                                              max_versions: max_filter_versions)
                           end
    end

    #: () -> Result
    def call
      return database_selection if @historical_filter.nil? && comparable_keys?

      candidates = versioned_ids
      candidates = @historical_filter.call(candidates) if @historical_filter && candidates.any?
      return Result.new(records: [], unreachable: []) if candidates.empty?

      live = live_ids(candidates)
      Result.new(
        records: selected_records(live),
        unreachable: (candidates - live).map { |id| identity(id) }.freeze
      )
    end

    private

    # @rbs @scope: untyped
    # @rbs @time_range: TimeRange?
    # @rbs @limit: Integer
    # @rbs @historical_filter: untyped

    # Leaves the candidate set in the database. Plucking every root changed in
    # the window would cost memory and a statement proportional to all activity
    # in the window -- not to the relation or `limit:` -- so a report on one
    # record could read every id in a busy table. A subquery keeps the work
    # bounded by what the relation and the deletions actually contain.
    #: () -> Result
    def database_selection
      candidates = window_versions.select(:item_id)
      Result.new(
        records: selected_records(candidates),
        unreachable: missing_ids.map { |id| identity(id) }.freeze
      )
    end

    # Comparing the two columns in SQL needs them to share a type: PostgreSQL
    # rejects an integer key against a string item_id outright.
    #: () -> bool
    def comparable_keys?
      return false unless primary_key.is_a?(String)

      item_id = version_class.columns_hash['item_id']&.type
      key = base_class.columns_hash[primary_key]&.type
      !item_id.nil? && item_id == key
    end

    # Changed in the window but without a row, found with an anti-join instead
    # of comparing two plucked lists.
    #: () -> Array[String]
    def missing_ids
      live = base_class.unscoped.select(primary_key)
      window_versions.where.not(item_id: live).distinct.pluck(:item_id).map(&:to_s).uniq.sort
    end

    #: () -> untyped
    def window_versions
      relation = version_class.where(item_type: item_type)
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

      relation = scope.all
      return relation if Support.versioned?(relation.model)

      raise UnversionedAssociationError,
            "scope: #{relation.model.name} is not versioned, so it has no history to select from"
    end

    #: (Integer) -> Integer
    def validate_limit(limit)
      return limit if limit.is_a?(Integer) && limit.positive?

      raise ConfigurationError, 'limit: must be a positive Integer'
    end

    # Every root whose history moved inside the window, destroyed ones included.
    # This is the gem's own notion of "which roots changed", answered from the
    # version table alone so that it does not depend on rows still existing.
    #: () -> Array[String]
    def versioned_ids
      window_versions.distinct.pluck(:item_id).map(&:to_s).uniq
    end

    # Which of those candidates still have a row, asked without the relation's
    # conditions so that "filtered out" and "no longer exists" stay separable.
    #: (Array[String]) -> Array[String]
    def live_ids(candidates)
      candidates.each_slice(PAGE_SIZE).flat_map do |slice|
        base_class.unscoped.where(primary_key => slice).pluck(primary_key).map(&:to_s)
      end
    end

    # Deduplicate records rather than adding SQL DISTINCT: an otherwise valid
    # relation may order by joined columns or select a PostgreSQL json column.
    # Read bounded pages until the relation ends or too many unique roots appear.
    #: (untyped) -> Array[untyped]
    def selected_records(live)
      return [] if live.is_a?(Array) && live.empty?

      records = {} #: Hash[untyped, untyped]
      consumed = 0
      loop do
        page = record_page(live, consumed)
        page.each { |record| records[record.id] ||= record }
        reject_oversized!(records.length)
        break if page.length < PAGE_SIZE

        consumed += page.length
      end
      records.values.freeze
    end

    #: (untyped, Integer) -> Array[untyped]
    def record_page(live, consumed)
      count = page_limit(consumed)
      return [] if count.zero?

      # An id list or a candidate subquery; both read the same way in SQL.
      conditions = { primary_key => live } #: Hash[untyped, untyped]
      ordered_scope.where(conditions)
                   .offset((@scope.offset_value || 0) + consumed).limit(count).to_a
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
      base_class.name.to_s
    end

    #: () -> untyped
    def base_class
      @scope.model.base_class
    end

    #: () -> untyped
    def primary_key
      @scope.model.primary_key
    end

    #: () -> untyped
    def version_class
      @scope.model.paper_trail.version_class
    end
  end
end
