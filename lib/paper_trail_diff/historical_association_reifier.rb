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
      # Keyed on record identity rather than `object_id`, which Ruby may reuse
      # once an earlier record in the same pass has been collected.
      reified = {} #: Hash[untyped, Hash[untyped, bool]]
      @reified_associations = reified.compare_by_identity
    end

    #: (untyped, Array[untyped]) -> void
    def reify(record, reflections)
      reflections.each { |reflection| reify_association(record, reflection) }
    end

    private

    # @rbs @transaction_id: untyped
    # @rbs @habtm_transaction_id: untyped
    # @rbs @version_at: untyped
    # @rbs @reified_associations: Hash[untyped, Hash[untyped, bool]]

    #: (untyped, untyped) -> void
    def reify_association(record, reflection)
      reified = @reified_associations[record] ||= {} #: Hash[untyped, bool]
      return if reified[reflection.name]

      reified[reflection.name] = true
      case reflection.macro
      when :belongs_to
        reify_belongs_to(record, reflection)
      when :has_one
        reifier(:HasOne).reify(reflection, record, options, @transaction_id)
      when :has_many
        reify_has_many(record, reflection)
      when :has_and_belongs_to_many
        reify_habtm(record, reflection)
      end
    end

    #: (untyped, untyped) -> void
    def reify_belongs_to(record, reflection)
      ensure_versioned_target!(record, reflection) if reflection.polymorphic?
      reifier(:BelongsTo).reify(reflection, record, options, @transaction_id)
    end

    # A polymorphic target's class is known only from the record's type
    # column, so TraversalPreparer cannot check it is versioned up front.
    #: (untyped, untyped) -> void
    def ensure_versioned_target!(record, reflection)
      model_class = AssociationTraversal.belongs_to_target(reflection, record)
      return if model_class.nil? || Support.versioned?(model_class)

      raise UnversionedAssociationError,
            "association #{record.class.name}##{reflection.name} cannot be compared " \
            "historically: it points at #{model_class.name}, which is not versioned. Add " \
            "`has_paper_trail` to #{model_class.name}, or mirror the fields you need onto a " \
            'model that has it.'
    end

    #: (untyped, untyped) -> void
    def reify_has_many(record, reflection)
      if reflection.options[:through]
        reify_association(record, reflection.through_reflection)
        reify_through(record, reflection)
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

    # PT-AT's collection-source helper reifies every has_many on each join
    # record. Walk only the requested source instead, including nested throughs.
    #: (untyped, untyped) -> void
    def reify_through(record, reflection)
      source = reflection.source_reflection
      if source.belongs_to?
        reifier(:HasManyThrough).reify(reflection, record, options, @transaction_id)
        return
      end

      members = through_members(record, reflection, source)
      association = record.association(reflection.name)
      association.target = members.uniq { |member| [member.class.base_class.name, member.id] }
      association.loaded!
    end

    #: (untyped, untyped, untyped) -> Array[untyped]
    def through_members(record, reflection, source)
      joins = Array(record.public_send(reflection.through_reflection.name)) #: Array[untyped]
      joins.flat_map do |join|
        reify_association(join, source)
        Array(join.public_send(source.name))
      end
    end

    #: (untyped, untyped) -> void
    def reify_habtm(record, reflection)
      unless @habtm_transaction_id
        message = 'HABTM reconstruction requires a transaction-backed endpoint version'
        raise IncompleteAssociationHistoryError, message
      end
      HabtmTransactionOwners.new(record.class, reflection)
                            .ensure_single_owner!(@habtm_transaction_id)

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
