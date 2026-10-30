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

      path, reason = self.class.fallback_paths(@traversal, model).first
      return unless path

      raise UnsupportedBatchPathError,
            "association #{path} requires per-record reconstruction (#{reason}); " \
            'remove this path or explicitly pass allow_expensive: true'
    end

    # Each requested path whose history prepared history cannot read, with
    # why. Such a path is read with PT-AT, one record at a time.
    #: (AssociationTraversal, untyped) -> Array[[String, String]]
    def self.fallback_paths(traversal, model)
      traversal.selected_reflections(model).filter_map do |path, reflection|
        reason = fallback_reason(reflection, ranked: true)
        [path, reason] if reason
      end
    end

    # A has_many through reads its parts' conditions only, at any depth. A
    # has_one through over a ranked part is refused whole, so its parts, too,
    # are checked for conditions alone.
    #: (untyped, ranked: bool) -> String?
    def self.fallback_reason(reflection, ranked:)
      reason = reason_for(reflection, ranked)
      return reason if reason || !reflection.through_reflection?

      [reflection.through_reflection, reflection.source_reflection].each do |part|
        part_reason = fallback_reason(part, ranked: false)
        return part_reason if part_reason
      end
      nil
    end
    private_class_method :fallback_reason

    # A scope prepared history can read as conditions on stored attributes
    # is batched like any other path. A polymorphic target's class, and so
    # its scope, is known only per record.
    #: (untyped, bool) -> String?
    def self.reason_for(reflection, ranked)
      return ('association scope' if reflection.scope) if reflection.polymorphic?
      if ranked && ScopeCondition.ranked_through?(reflection)
        return 'limit, offset or has_one order inside a has_one through'
      end
      return if ScopeCondition.build(reflection, ranked: ranked)

      reflection.scope ? 'association scope' : 'default-scoped target'
    end
    private_class_method :reason_for

    # @rbs @traversal: AssociationTraversal
    # @rbs @allow_expensive: bool
  end
end
