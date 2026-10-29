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

    # A has_many through reads its parts' conditions only, at any depth. A
    # has_one through over a ranked part is refused whole, so its parts, too,
    # are checked for conditions alone.
    #: (untyped, String, ?ranked: bool) -> void
    def check(reflection, path, ranked: true)
      reason = reason_for(reflection, ranked)
      if reason
        raise UnsupportedBatchPathError,
              "association #{path} requires per-record reconstruction (#{reason}); " \
              'remove this path or explicitly pass allow_expensive: true'
      end
      return unless reflection.through_reflection?

      [reflection.through_reflection, reflection.source_reflection].each do |part|
        check(part, path, ranked: false)
      end
    end

    # A scope prepared history can read as conditions on stored attributes
    # is batched like any other path. A polymorphic target's class, and so
    # its scope, is known only per record.
    #: (untyped, bool) -> String?
    def reason_for(reflection, ranked)
      return ('association scope' if reflection.scope) if reflection.polymorphic?
      if ranked && ScopeCondition.ranked_through?(reflection)
        return 'limit, offset or has_one order inside a has_one through'
      end
      return if ScopeCondition.build(reflection, ranked: ranked)

      reflection.scope ? 'association scope' : 'default-scoped target'
    end
  end
end
