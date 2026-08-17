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
    Result = Data.define(:records, :unreachable)

    #: (untyped, time_range: TimeRange?, limit: Integer) -> void
    def initialize(scope, time_range:, limit:)
      @scope = normalize_scope(scope)
      @time_range = time_range
      @limit = validate_limit(limit)
    end

    #: () -> Result
    def call
      candidates = versioned_ids
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

    # Accepts a model class as readily as a relation: `Article` and
    # `Article.where(...)` both name a population, and `all` is what makes them
    # the same kind of thing.
    #: (untyped) -> untyped
    def normalize_scope(scope)
      unless scope.respond_to?(:all) && scope.respond_to?(:where)
        raise ConfigurationError, 'scope: must be an ActiveRecord relation or model class'
      end

      relation = scope.all
      return relation if versioned?(relation.model)

      raise UnversionedAssociationError,
            "scope: #{relation.model.name} is not versioned, so it has no history to select from"
    end

    # `paper_trail` is defined on every model, so its presence proves nothing.
    # Only configured options distinguish a model that called has_paper_trail.
    #: (untyped) -> bool
    def versioned?(model_class)
      model_class.respond_to?(:paper_trail_options) && !model_class.paper_trail_options.nil?
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
      relation = version_class.where(item_type: item_type)
      range = @time_range
      relation = range.scope(relation) if range
      relation.distinct.pluck(:item_id).map(&:to_s).uniq
    end

    # Which of those candidates still have a row, asked without the relation's
    # conditions so that "filtered out" and "no longer exists" stay separable.
    #: (Array[String]) -> Array[String]
    def live_ids(candidates)
      base_class.unscoped.where(primary_key => candidates).pluck(primary_key).map(&:to_s)
    end

    # Loading one past the limit is what turns an oversized page into an error
    # rather than a silently truncated report.
    #: (Array[String]) -> Array[untyped]
    def selected_records(live)
      return [] if live.empty?

      records = @scope.where(primary_key => live).limit(@limit + 1).to_a
      return records.freeze unless records.length > @limit

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
