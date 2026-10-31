# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Which associations Active Record's preloader loads correctly for many
  # owners at once.
  module BatchPreload
    # The preloader applies a limit or offset to all owners' records at once,
    # not to each owner's, so such an association is loaded per record. A
    # has_one is no exception. Through a part with a limit, an offset or a
    # has_one cut, the preloader keeps what the part alone would load, while
    # the through's own query keeps the part's conditions only.
    #
    # The declared scope is read, not a record's association scope: Active
    # Record adds `limit(1)` to every has_one's, which would load every
    # has_one per record.
    #: (untyped) -> bool
    def self.safe?(reflection)
      scope = reflection.scope
      return false if scope && !scope.arity.zero?
      return true unless reflection.collection? || reflection.has_one?
      return false if cut_part?(reflection)

      relation = declared_relation(reflection)
      relation.limit_value.nil? && relation.offset_value.nil?
    end

    #: (untyped) -> untyped
    def self.declared_relation(reflection)
      relation = reflection.klass.default_scoped
      reflection.scope ? reflection.scope_for(relation) : relation
    end
    private_class_method :declared_relation

    #: (untyped) -> bool
    def self.cut_part?(reflection)
      reflection.collection? &&
        (ScopeCondition.ranked_parts?(reflection) || through_parts(reflection).any?(&:has_one?))
    end
    private_class_method :cut_part?

    # Every part a through passes, at any depth.
    #: (untyped) -> Array[untyped]
    def self.through_parts(reflection)
      return [] unless reflection.through_reflection?

      [reflection.through_reflection, reflection.source_reflection].flat_map do |part|
        [part, *through_parts(part)]
      end
    end
    private_class_method :through_parts
  end
end
