# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The requested paths prepared history cannot read exactly, each with why.
  # PT-AT reads such a path instead, one record at a time, when the caller
  # passes `allow_approximate: true`.
  module ApproximatePaths
    #: (AssociationTraversal, untyped) -> Array[[String, String]]
    def self.call(traversal, model)
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
  end
end
