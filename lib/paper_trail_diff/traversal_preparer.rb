# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Checks that a model can be traversed before any reconstruction starts, and
  # that association tracking is actually available when history is involved.
  class TraversalPreparer
    #: (tree: AssociationTree, traversal: AssociationTraversal) -> void
    def initialize(tree:, traversal:)
      @tree = tree
      @traversal = traversal
    end

    #: (untyped, historical: bool) -> void
    def call(model_class, historical:)
      return if @tree.empty?

      ensure_association_tracking! if historical
      @traversal.validate!(model_class)
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal

    #: () -> void
    def ensure_association_tracking!
      paper_trail = Object.const_get(:PaperTrail) #: untyped
      config = paper_trail.config #: untyped
      available = defined?(::PaperTrailAssociationTracking) &&
                  config.respond_to?(:track_associations?) &&
                  config.track_associations?
      return if available

      message = 'association tracking must be loaded and enabled to compare historical associations'
      raise AssociationTrackingUnavailableError, message
    end
  end
end
