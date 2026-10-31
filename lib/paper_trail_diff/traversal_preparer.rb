# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Checks that a model can be traversed before any reconstruction starts, and
  # that association tracking is actually available when history is involved.
  # `diagnose` reports the same refusals instead of raising the first.
  class TraversalPreparer
    # One reason to refuse a request: the error `call` raises, and the code
    # and path `diagnose` reports.
    class Refusal
      attr_reader :error #: untyped
      attr_reader :code #: Symbol
      attr_reader :message #: String
      attr_reader :path #: String?

      #: (untyped, Symbol, String, ?String?) -> void
      def initialize(error, code, message, path = nil)
        @error = error
        @code = code
        @message = message
        @path = path
        freeze
      end
    end

    #: (tree: AssociationTree, traversal: AssociationTraversal, ?allow_approximate: bool) -> void
    def initialize(tree:, traversal:, allow_approximate: false)
      unless [true, false].include?(allow_approximate)
        raise ConfigurationError, 'allow_approximate: must be true or false'
      end

      @tree = tree
      @traversal = traversal
      @allow_approximate = allow_approximate
      @refusals = {} #: Hash[Array[untyped], Array[Refusal]]
    end

    #: (untyped, historical: bool) -> void
    def call(model_class, historical:)
      refusal = refusals(model_class, historical: historical).first
      raise refusal.error, refusal.message if refusal
    end

    # Every reason to refuse a request over the model, in the order `call`
    # raises them. Live-to-live comparison reads current state, so only the
    # traversal itself is checked for it.
    #: (untyped, historical: bool) -> Array[Refusal]
    def refusals(model_class, historical:)
      return [] if @tree.empty?

      @refusals[[model_class, historical]] ||= collect(model_class, historical).freeze
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @allow_approximate: bool
    # @rbs @refusals: Hash[Array[untyped], Array[Refusal]]

    #: (untyped, bool) -> Array[Refusal]
    def collect(model_class, historical)
      found = [] #: Array[Refusal]
      found << tracking_refusal if historical && !association_tracking?
      unresolved = traversal_refusal(model_class)
      return found << unresolved if unresolved
      return found unless historical

      found.concat(unversioned_refusals(model_class), approximate_refusals(model_class))
    end

    #: (untyped) -> Refusal?
    def traversal_refusal(model_class)
      @traversal.validate!(model_class)
      nil
    rescue UnknownAssociationError, UnsupportedAssociationError => e
      code = e.is_a?(UnknownAssociationError) ? :unknown_association : :unsupported_association
      Refusal.new(e.class, code, e.message)
    end

    # A path prepared history cannot read is read with PT-AT, which rebuilds
    # an association from its current members, swapping in older versions of
    # them. A record that entered the association since, such as one moved
    # into a scope or restored from a soft delete, then reads as a member it
    # was not, and one that left reads as missing. Only a caller who accepts
    # that may read such a path.
    #: (untyped) -> Array[Refusal]
    def approximate_refusals(model_class)
      return [] if @allow_approximate

      BatchSafety.fallback_paths(@traversal, model_class).map do |path, reason|
        message = "association #{path} cannot be read exactly from history (#{reason}): " \
                  'PT-AT rebuilds it from its current members, so a record that entered or ' \
                  'left it since is reported wrongly; remove this path, make its scope plain ' \
                  'conditions on the target\'s own columns, or pass allow_approximate: true'
        Refusal.new(UnsupportedAssociationError, :approximate_association, message, path)
      end
    end

    # A model PaperTrail never versioned has no history to reconstruct, so a
    # comparison over it can only ever answer "nothing changed" -- which is a
    # wrong answer rather than an empty one. Live-to-live comparison reads
    # current state and is unaffected, so this applies to historical work only.
    #: (untyped) -> Array[Refusal]
    def unversioned_refusals(model_class)
      @traversal.selected_reflections(model_class).flat_map do |path, reflection|
        # A polymorphic target is not known until a row names it; `diagnose`
        # reports that separately rather than guessing here.
        next [] if reflection.polymorphic?

        target = reflection.klass
        through = through_models(reflection).flat_map do |model|
          unversioned(path, model, :unversioned_through_model,
                      "it goes through #{model.name}, which is not versioned")
        end
        unversioned(path, target, :unversioned_association_target,
                    "#{target.name} is not versioned") + through
      end
    end

    # A has_many :through reads past membership from the versions of the
    # models it goes through, so each of them needs history too.
    #: (untyped) -> Array[untyped]
    def through_models(reflection)
      return [] unless reflection.through_reflection?

      [reflection.through_reflection, reflection.source_reflection].flat_map do |part|
        part.polymorphic? ? through_models(part) : [part.klass, *through_models(part)]
      end.uniq - [reflection.klass]
    end

    #: (String, untyped, Symbol, String) -> Array[Refusal]
    def unversioned(path, model_class, code, problem)
      return [] if Support.versioned?(model_class)

      message = "association #{path} cannot be compared historically: #{problem}. " \
                "Add `has_paper_trail` to #{model_class.name}, or mirror the fields you need " \
                'onto a model that has it.'
      [Refusal.new(UnversionedAssociationError, code, message, path)]
    end

    #: () -> bool
    def association_tracking?
      paper_trail = Object.const_get(:PaperTrail) #: untyped
      config = paper_trail.config #: untyped
      !!(defined?(::PaperTrailAssociationTracking) &&
        config.respond_to?(:track_associations?) && config.track_associations?)
    end

    #: () -> Refusal
    def tracking_refusal
      Refusal.new(AssociationTrackingUnavailableError, :association_tracking_unavailable,
                  'association tracking must be loaded and enabled to compare historical ' \
                  'associations')
    end
  end
end
