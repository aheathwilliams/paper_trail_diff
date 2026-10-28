# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Resolves `:first` endpoints for a whole batch in a fixed number of queries per
  # model class. Left to the caller this is a per-root lookup, which reintroduces
  # exactly the queries a batched comparison exists to remove.
  class BatchBoundaryResolver
    BOUNDARIES = %i[first].freeze

    class << self
      #: (untyped) -> bool
      def symbolic?(endpoint)
        endpoint.is_a?(Symbol)
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
      return @pairs unless @pairs.flatten(1).any? { |endpoint| symbolic?(endpoint) }

      index = boundary_index
      @pairs.map do |from, to|
        [resolve(from, to, index), resolve(to, from, index)]
      end
    end

    private

    # @rbs @pairs: Array[[untyped, untyped]]

    #: (untyped) -> bool
    def symbolic?(endpoint)
      self.class.symbolic?(endpoint)
    end

    #: (untyped, untyped, Hash[Array[String], Hash[Symbol, untyped]]) -> untyped
    def resolve(endpoint, other, index)
      return endpoint unless symbolic?(endpoint)
      raise ConfigurationError, TimelineRange::LAST_REMOVED if endpoint == :last

      unless BOUNDARIES.include?(endpoint)
        raise ConfigurationError,
              "unsupported boundary: #{endpoint.inspect}; use :first, a version, or a record"
      end

      identity = anchor_identity(other)
      unless identity
        raise ConfigurationError,
              'a :first endpoint needs the other endpoint to name a record'
      end

      index.dig(identity, endpoint) || endpoint
    end

    # A symbol carries no identity of its own, so the pair's other endpoint has
    # to say which record is meant.
    #: (untyped) -> Array[String]?
    def anchor_identity(endpoint)
      return if endpoint.nil? || symbolic?(endpoint)

      Endpoint.identity(endpoint)
    rescue InvalidEndpointError
      nil
    end

    #: () -> Hash[Array[String], Hash[Symbol, untyped]]
    def boundary_index
      index = {} #: Hash[Array[String], Hash[Symbol, untyped]]
      anchors.group_by { |model_class, _id| model_class }.each do |model_class, entries|
        add_model_boundaries(index, model_class, entries.map { |_klass, id| id }.uniq)
      end
      index
    end

    #: () -> Array[[untyped, untyped]]
    def anchors
      @pairs.flatten(1).filter_map { |endpoint| anchor(endpoint) }.uniq
    end

    #: (untyped) -> [untyped, untyped]?
    def anchor(endpoint)
      return if endpoint.nil? || symbolic?(endpoint)

      if Endpoint.version?(endpoint)
        [Endpoint.model_class(endpoint), endpoint.item_id]
      elsif Endpoint.record?(endpoint)
        [endpoint.class, endpoint.id]
      end
    rescue InvalidEndpointError
      nil
    end

    #: (Hash[Array[String], Hash[Symbol, untyped]], untyped, Array[untyped]) -> void
    def add_model_boundaries(index, model_class, ids)
      firsts = first_versions(model_class, ids)
      ids.each do |id|
        index[identity_key(model_class, id)] = { first: firsts[id.to_s] }
      end
    end

    # Each root's earliest version by time, in one query whatever the size of
    # the batch. The lowest id is not the earliest version when ids are not
    # sequential, as with UUIDs, so time decides and the usual ordering breaks
    # a tie -- refusing one that ids cannot order.
    #: (untyped, Array[untyped]) -> Hash[String, untyped]
    def first_versions(model_class, ids)
      version_class = model_class.paper_trail.version_class
      table = version_class.arel_table
      candidates = version_class.where(item_type: model_class.base_class.name.to_s, item_id: ids)
                                .where(VersionQuery.no_earlier_version(table)).to_a
      candidates.group_by { |version| version.item_id.to_s }
                .transform_values { |versions| Support.chronological_sort(versions).first }
    end

    #: (untyped, untyped) -> Array[String]
    def identity_key(model_class, id)
      [model_class.base_class.name.to_s, id.to_s]
    end
  end
end
