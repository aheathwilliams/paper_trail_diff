# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Sets a rebuilt record's associations to their members in loaded history.
  class PreparedAssociationReifier
    #: (PreparedHistory?, untyped) -> void
    def initialize(history, boundary)
      @history = history
      @boundary = boundary
      # Keyed on record identity rather than `object_id`, which Ruby may reuse
      # once an earlier record in the same pass has been collected.
      reified = {} #: Hash[untyped, Hash[untyped, bool]]
      @reified = reified.compare_by_identity
    end

    #: (untyped, Array[untyped]) -> void
    def reify(record, reflections)
      reflections.each { |reflection| reify_association(record, reflection) }
    end

    private

    # @rbs @history: PreparedHistory?
    # @rbs @boundary: untyped
    # @rbs @reified: Hash[untyped, Hash[untyped, bool]]

    #: (untyped, untyped) -> void
    def reify_association(record, reflection)
      reified = @reified[record] ||= {} #: Hash[untyped, bool]
      return if reified[reflection.name]

      reified[reflection.name] = true
      handled, records = @history&.resolve(record, reflection, @boundary)
      unreadable!(record, reflection) unless handled && records

      association = record.association(reflection.name)
      association.target = reflection.collection? ? records : records.first
      association.loaded!
    end

    # A polymorphic target's class is known only from the record's type
    # column, so TraversalPreparer cannot check it up front: it may have no
    # versions, or a default scope history cannot read.
    #: (untyped, untyped) -> bot
    def unreadable!(record, reflection)
      name = "#{record.class.name}##{reflection.name}"
      target = AssociationTraversal.belongs_to_target(reflection, record) if reflection.polymorphic?
      unless target.nil? || Support.versioned?(target)
        raise UnversionedAssociationError,
              "association #{name} cannot be compared historically: it points at " \
              "#{target.name}, which is not versioned. Add `has_paper_trail` to " \
              "#{target.name}, or mirror the fields you need onto a model that has it."
      end

      raise UnsupportedAssociationError,
            "association #{name} cannot be read from history for #{record.class.name} " \
            "#{record.id.inspect}: who was in it at a past point cannot be told"
    end
  end
end
