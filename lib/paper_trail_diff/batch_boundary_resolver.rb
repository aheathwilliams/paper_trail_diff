# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Resolves `:first` endpoints for a whole batch in one query per 500 roots
  # of a model class. Left to the caller this is a per-root lookup, which
  # reintroduces exactly the queries a batched comparison exists to remove.
  class BatchBoundaryResolver
    class << self
      #: (untyped) -> bool
      def symbolic?(endpoint)
        endpoint.instance_of?(Symbol)
      end
    end

    #: (Array[[untyped, untyped]]) -> void
    def initialize(pairs)
      @pairs = pairs
    end

    # Returns the pairs with every resolvable symbol replaced. A symbol that
    # names history the record does not have is left in place, so the caller can
    # decide what an absent history means rather than being handed nil.
    #: () -> Array[[untyped, untyped]]
    def call
      return @pairs unless @pairs.flatten.any? { |endpoint| symbolic?(endpoint) }

      firsts = first_versions
      @pairs.map do |from, to|
        [resolve(from, to, firsts), resolve(to, from, firsts)]
      end
    end

    private

    # @rbs @pairs: Array[[untyped, untyped]]

    #: (untyped) -> bool
    def symbolic?(endpoint)
      self.class.symbolic?(endpoint)
    end

    #: (untyped, untyped, Hash[Array[String], untyped]) -> untyped
    def resolve(endpoint, other, firsts)
      return endpoint unless symbolic?(endpoint)

      TimelineRange.check_symbol!(endpoint)

      identity = anchor_identity(other)
      unless identity
        raise ConfigurationError,
              'a :first endpoint needs the other endpoint to name a record'
      end

      firsts[identity] || endpoint
    end

    # A symbol carries no identity of its own, so the pair's other endpoint has
    # to say which record is meant.
    #: (untyped) -> Array[String]?
    def anchor_identity(endpoint)
      Endpoint.identity(endpoint)
    rescue InvalidEndpointError
      nil
    end

    # Each named record's earliest version, by the record's identity, in one
    # statement for each 500 records of a model class.
    #: () -> Hash[Array[String], untyped]
    def first_versions
      firsts = {} #: Hash[Array[String], untyped]
      anchors.group_by(&:first).each do |model_class, entries|
        firsts.merge!(first_versions_of(model_class, entries.map(&:last)))
      end
      firsts
    end

    # The model of each endpoint that names a record, with the record or its
    # versions' id: a query reads a record's own id, as BatchedRootVersions'
    # does. A version of a model that no longer exists names none, so its pair
    # keeps its symbol.
    #: () -> Array[[untyped, untyped]]
    def anchors
      @pairs.flatten.filter_map { |endpoint| anchor(endpoint) }
    end

    #: (untyped) -> [untyped, untyped]?
    def anchor(endpoint)
      if Endpoint.version?(endpoint)
        [Endpoint.model_class(endpoint), endpoint.item_id]
      elsif Endpoint.record?(endpoint)
        [endpoint.class, endpoint]
      end
    rescue InvalidEndpointError
      nil
    end

    # Each root's earliest version by time, in one query for every 500 roots.
    # The lowest id is not the earliest version when ids are not
    # sequential, as with UUIDs, so time decides and the usual ordering breaks
    # a tie -- refusing one that ids cannot order.
    #: (untyped, Array[untyped]) -> Hash[Array[String], untyped]
    def first_versions_of(model_class, ids)
      table = model_class.paper_trail.version_class.arel_table
      first = VersionQuery.no_earlier_version(table)
      candidates = ids.each_slice(Support::IDS_PER_STATEMENT).flat_map do |slice|
        VersionQuery.for_items(model_class, slice).where(first)
      end
      candidates.group_by { |version| Support.record_identity(model_class, version.item_id) }
                .transform_values { |versions| Support.chronological_sort(versions).first }
    end
  end
end
