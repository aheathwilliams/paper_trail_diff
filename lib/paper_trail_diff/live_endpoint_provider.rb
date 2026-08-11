# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects safe reload or validated caller-owned loading for current endpoints.
  class LiveEndpointProvider
    attr_reader :reload #: bool
    attr_reader :comparison_payload #: Hash[Symbol, untyped]

    #: (tree: AssociationTree, traversal: AssociationTraversal, reload: bool) -> void
    def initialize(tree:, traversal:, reload:)
      unless [true, false].include?(reload)
        raise ConfigurationError, 'reload_live_endpoints: must be true or false'
      end

      @reload = reload
      @comparison_payload = Instrumentation.comparison_payload(
        association_paths: tree.paths,
        reload_live_endpoints: reload
      ).freeze
      @loader = if reload
                  LiveEndpointBatchLoader.new(tree: tree)
                else
                  PreloadedEndpointBatchLoader.new(tree: tree, traversal: traversal)
                end
      @loaded = {} #: Hash[identity, untyped]
    end

    # Loads each endpoint at most once for the life of this provider, which is
    # one public call. A batch that resolves every root up front and then asks
    # again for one of them costs nothing the second time, and every root in the
    # result reflects the same instant rather than whenever its turn came.
    #: (Array[untyped]) -> Hash[identity, untyped]
    def call(records)
      missing = records.reject { |record| @loaded.key?(Endpoint.identity(record)) }
      return known(records) if missing.empty?

      loaded = Instrumentation.instrument('load_live_endpoints', payload(missing)) do
        @loader.call(missing)
      end
      @loaded.merge!(loaded)
      known(records)
    end

    private

    # @rbs @loader: untyped
    # @rbs @loaded: Hash[identity, untyped]

    #: (Array[untyped]) -> Hash[identity, untyped]
    def known(records)
      records.to_h do |record|
        identity = Endpoint.identity(record)
        [identity, @loaded.fetch(identity)]
      end
    end

    #: (Array[untyped]) -> Hash[Symbol, untyped]
    def payload(records)
      {
        endpoint_count: records.length,
        model_types: records.map { |record| record.class.base_class.name.to_s }.uniq.sort.freeze,
        reload_live_endpoints: reload
      }
    end
  end
end
