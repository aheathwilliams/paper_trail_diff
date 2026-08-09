# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Resolves indexed associations and delegates unsupported reflections to PT-AT.
  class PreparedAssociationReifier
    #: (PreparedHistory, untyped, habtm_boundary: untyped, fallback: HistoricalAssociationReifier) -> void
    def initialize(history, boundary, habtm_boundary:, fallback:)
      @history = history
      @boundary = boundary
      @habtm_boundary = habtm_boundary
      @fallback = fallback
      @reified = {} #: Hash[Array[untyped], bool]
    end

    #: (untyped, Array[untyped]) -> void
    def reify(record, reflections)
      reflections.each { |reflection| reify_association(record, reflection) }
    end

    private

    # @rbs @history: PreparedHistory
    # @rbs @boundary: untyped
    # @rbs @habtm_boundary: untyped
    # @rbs @fallback: HistoricalAssociationReifier
    # @rbs @reified: Hash[Array[untyped], bool]

    #: (untyped, untyped) -> void
    def reify_association(record, reflection)
      key = [record.object_id, reflection.name]
      return if @reified[key]

      @reified[key] = true
      handled, records = @history.resolve(
        record,
        reflection,
        @boundary,
        habtm_boundary: @habtm_boundary
      )
      return @fallback.reify(record, [reflection]) unless handled

      association = record.association(reflection.name)
      association.target = reflection.collection? ? records : records.first
      association.loaded!
    end
  end
end
