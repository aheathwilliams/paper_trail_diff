# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Refuses known per-record association loading before a batch reconstructs it.
  class BatchSafety
    #: (AssociationTraversal, allow_expensive: bool) -> void
    def initialize(traversal, allow_expensive:)
      unless [true, false].include?(allow_expensive)
        raise ConfigurationError, 'allow_expensive: must be true or false'
      end

      @traversal = traversal
      @allow_expensive = allow_expensive
    end

    #: (untyped) -> void
    def call(model)
      return if @allow_expensive

      @traversal.selected_reflections(model).each do |path, reflection|
        check(reflection, path)
      end
    end

    private

    # @rbs @traversal: AssociationTraversal
    # @rbs @allow_expensive: bool

    #: (untyped, String) -> void
    def check(reflection, path)
      reason = reason_for(reflection)
      if reason
        raise UnsupportedBatchPathError,
              "association #{path} requires per-record reconstruction (#{reason}); " \
              'remove this path or explicitly pass allow_expensive: true'
      end
      return unless reflection.through_reflection?

      [reflection.through_reflection, reflection.source_reflection].each do |part|
        check(part, path)
      end
    end

    #: (untyped) -> String?
    def reason_for(reflection)
      return 'association scope' if reflection.scope

      'default-scoped target' if !reflection.polymorphic? && reflection.klass.default_scopes?
    end
  end
end
