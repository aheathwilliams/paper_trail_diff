# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Checks that a model can be traversed before any reconstruction starts, and
  # that association tracking is actually available when history is involved.
  class TraversalPreparer
    #: (tree: AssociationTree, traversal: AssociationTraversal, ?allow_approximate: bool) -> void
    def initialize(tree:, traversal:, allow_approximate: false)
      unless [true, false].include?(allow_approximate)
        raise ConfigurationError, 'allow_approximate: must be true or false'
      end

      @tree = tree
      @traversal = traversal
      @allow_approximate = allow_approximate
      @exact = {} #: Hash[untyped, bool]
    end

    #: (untyped, historical: bool) -> void
    def call(model_class, historical:)
      return if @tree.empty?

      ensure_association_tracking! if historical
      @traversal.validate!(model_class)
      return unless historical

      ensure_versioned_targets!(model_class)
      ensure_exact_membership!(model_class)
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @allow_approximate: bool
    # @rbs @exact: Hash[untyped, bool]

    # A path prepared history cannot read is read with PT-AT, which rebuilds
    # an association from its current members, swapping in older versions of
    # them. A record that entered the association since, such as one moved
    # into a scope or restored from a soft delete, then reads as a member it
    # was not, and one that left reads as missing. Only a caller who accepts
    # that may read such a path.
    #: (untyped) -> void
    def ensure_exact_membership!(model_class)
      return if @allow_approximate || @exact[model_class]

      path, reason = BatchSafety.fallback_paths(@traversal, model_class).first
      if path
        raise UnsupportedAssociationError,
              "association #{path} cannot be read exactly from history (#{reason}): " \
              'PT-AT rebuilds it from its current members, so a record that entered or ' \
              'left it since is reported wrongly; remove this path, make its scope plain ' \
              'conditions on the target\'s own columns, or pass allow_approximate: true'
      end
      @exact[model_class] = true
    end

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
      Support.versioned?(model_class)
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
