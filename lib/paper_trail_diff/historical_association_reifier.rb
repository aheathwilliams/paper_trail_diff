# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reconstructs selected nested edges at one root PaperTrail endpoint.
  class HistoricalAssociationReifier
    #: (untyped, ?habtm_version: untyped) -> void
    def initialize(version, habtm_version: version)
      @transaction_id = version.transaction_id if version.respond_to?(:transaction_id)
      if habtm_version.respond_to?(:transaction_id)
        @habtm_transaction_id = habtm_version.transaction_id
      end
      @version_at = version.created_at
    end

    #: (untyped, Array[untyped]) -> void
    def reify(record, reflections)
      reflections.each { |reflection| reify_association(record, reflection) }
    end

    private

    # @rbs @transaction_id: untyped
    # @rbs @habtm_transaction_id: untyped
    # @rbs @version_at: untyped

    #: (untyped, untyped) -> void
    def reify_association(record, reflection)
      case reflection.macro
      when :belongs_to
        reifier(:BelongsTo).reify(reflection, record, options, @transaction_id)
      when :has_one
        reifier(:HasOne).reify(reflection, record, options, @transaction_id)
      when :has_many
        reify_has_many(record, reflection)
      when :has_and_belongs_to_many
        reify_habtm(record, reflection)
      end
    end

    #: (untyped, untyped) -> void
    def reify_has_many(record, reflection)
      if reflection.options[:through]
        reifier(:HasManyThrough).reify(reflection, record, options, @transaction_id)
        return
      end

      version_table = record.class.paper_trail.version_class.table_name
      reifier(:HasMany).reify(
        reflection,
        record,
        options,
        @transaction_id,
        version_table
      )
    end

    #: (untyped, untyped) -> void
    def reify_habtm(record, reflection)
      unless @habtm_transaction_id
        message = 'HABTM reconstruction requires a transaction-backed endpoint version'
        raise IncompleteAssociationHistoryError, message
      end

      paper_trail = Object.const_get(:PaperTrail) #: untyped
      target_versioned = paper_trail.request.enabled_for_model?(reflection.klass)
      reifier(:HasAndBelongsToMany).reify(
        target_versioned,
        reflection,
        record,
        options,
        @habtm_transaction_id
      )
    end

    #: () -> Hash[Symbol, untyped]
    def options
      {
        dup: true,
        mark_for_destruction: false,
        unversioned_attributes: :nil,
        version_at: @version_at
      }
    end

    #: (Symbol) -> untyped
    def reifier(name)
      tracking = Object.const_get(:PaperTrailAssociationTracking) #: untyped
      reifiers = tracking.const_get(:Reifiers) #: untyped
      reifiers.const_get(name)
    rescue NameError => e
      message = 'loaded association tracking does not support nested reconstruction'
      raise AssociationTrackingUnavailableError, message, cause: e
    end
  end
end
