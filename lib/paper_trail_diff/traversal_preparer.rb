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
      ensure_versioned_targets!(model_class) if historical
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal

    # A model PaperTrail never versioned has no history to reconstruct, so a
    # comparison over it can only ever answer "nothing changed" -- which is a
    # wrong answer rather than an empty one. Live-to-live comparison reads
    # current state and is unaffected, so this applies to historical work only.
    #: (untyped) -> void
    def ensure_versioned_targets!(model_class)
      @traversal.selected_reflections(model_class).each do |path, reflection|
        # A polymorphic target is not known until a row names it; `diagnose`
        # reports that separately rather than guessing here.
        next if reflection.polymorphic?
        next if versioned?(reflection.klass)

        raise UnversionedAssociationError,
              "association #{path} cannot be compared historically: " \
              "#{reflection.klass.name} is not versioned. Add `has_paper_trail` to it, " \
              'or mirror the fields you need onto a model that has it.'
      end
    end

    #: (untyped) -> bool
    def versioned?(model_class)
      model_class.respond_to?(:paper_trail_options) && !model_class.paper_trail_options.nil?
    end

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
