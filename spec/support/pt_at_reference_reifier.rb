# frozen_string_literal: true

module PaperTrailDiff
  # PT-AT's own reconstruction of selected nested edges at one root version:
  # the independent reference the specs compare loaded history against.
  class PtAtReferenceReifier
    def initialize(version)
      @transaction_id = VersionBoundary.transaction_id(version)
      @version_at = version.created_at
      # Keyed on record identity rather than `object_id`, which Ruby may reuse
      # once an earlier record in the same pass has been collected.
      reified = {}
      @reified_associations = reified.compare_by_identity
    end

    def reify(record, reflections)
      reflections.each { |reflection| reify_association(record, reflection) }
    end

    private

    def reify_association(record, reflection)
      reified = @reified_associations[record] ||= {}
      return if reified[reflection.name]

      reified[reflection.name] = true
      case reflection.macro
      when :belongs_to
        reify_belongs_to(record, reflection)
      when :has_one
        reifier(:HasOne).reify(reflection, record, options, @transaction_id)
      when :has_many
        reify_has_many(record, reflection)
      end
    end

    def reify_belongs_to(record, reflection)
      ensure_versioned_target!(record, reflection) if reflection.polymorphic?
      reifier(:BelongsTo).reify(reflection, record, options, @transaction_id)
    end

    # A polymorphic target's class is known only from the record's type
    # column, so TraversalPreparer cannot check it is versioned up front.
    def ensure_versioned_target!(record, reflection)
      model_class = AssociationTraversal.belongs_to_target(reflection, record)
      return if model_class.nil? || Support.versioned?(model_class)

      raise UnversionedAssociationError,
            "association #{record.class.name}##{reflection.name} cannot be compared " \
            "historically: it points at #{model_class.name}, which is not versioned. Add " \
            "`has_paper_trail` to #{model_class.name}, or mirror the fields you need onto a " \
            'model that has it.'
    end

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
    def reify_through(record, reflection)
      source = reflection.source_reflection
      if pt_at_source?(reflection)
        reifier(:HasManyThrough).reify(reflection, record, options, @transaction_id)
        return
      end

      members = through_members(record, reflection, source)
      association = record.association(reflection.name)
      association.target = members.uniq do |member|
        Support.record_identity(member.class, member.id)
      end
      association.loaded!
    end

    # PT-AT's belongs_to source ignores `source_type:` and reads targets by id
    # alone, so a typed through walks its join records instead.
    def pt_at_source?(reflection)
      reflection.source_reflection.belongs_to? && !reflection.options[:source_type]
    end

    def through_members(record, reflection, source)
      joins = Array(record.public_send(reflection.through_reflection.name))
      joins = joins.select { |join| AssociationTraversal.source_type_join?(reflection, join) }
      joins.flat_map do |join|
        reify_association(join, source)
        Array(join.public_send(source.name))
      end
    end

    def options
      {
        dup: true,
        mark_for_destruction: false,
        unversioned_attributes: :nil,
        version_at: @version_at
      }
    end

    def reifier(name)
      tracking = Object.const_get(:PaperTrailAssociationTracking)
      reifiers = tracking.const_get(:Reifiers)
      reifiers.const_get(name)
    rescue NameError => e
      message = 'loaded association tracking does not support nested reconstruction'
      raise AssociationTrackingUnavailableError, message, cause: e
    end
  end
end
