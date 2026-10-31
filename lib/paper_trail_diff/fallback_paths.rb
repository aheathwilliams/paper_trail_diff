# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Whether a request may read a path with PT-AT's reifier rather than from
  # loaded history. PT-AT places association changes by timestamp alone, so
  # only such a path can miss a change between two versions that share one;
  # loaded history orders those versions by id.
  module FallbackPaths
    # A path history reads only approximately counts when it is allowed: a
    # request that does not allow it is refused before anything is read.
    #: (AssociationTraversal, untyped, approximate: bool) -> bool
    def self.any?(traversal, model, approximate:)
      return true if approximate && !ApproximatePaths.call(traversal, model).empty?

      traversal.selected_reflections(model).any? { |_path, reflection| per_record?(reflection) }
    end

    # Loaded history cannot index a composite foreign key, and a polymorphic
    # belongs_to's target, with its default scope, is known only per record.
    #: (untyped) -> bool
    def self.per_record?(reflection)
      composite_key?(reflection) || (reflection.belongs_to? && reflection.polymorphic?)
    end
    private_class_method :per_record?

    #: (untyped) -> bool
    def self.composite_key?(reflection)
      return true if reflection.foreign_key.is_a?(Array)
      return false unless reflection.through_reflection?

      [reflection.through_reflection, reflection.source_reflection].any? do |part|
        composite_key?(part)
      end
    end
    private_class_method :composite_key?
  end
end
