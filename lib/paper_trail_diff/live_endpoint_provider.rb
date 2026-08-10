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
    end

    #: (Array[untyped]) -> Hash[identity, untyped]
    def call(records)
      Instrumentation.instrument('load_live_endpoints', payload(records)) do
        @loader.call(records)
      end
    end

    private

    # @rbs @loader: untyped

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
