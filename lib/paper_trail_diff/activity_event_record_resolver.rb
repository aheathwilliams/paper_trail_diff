# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reconstructs an event's post-change record or immutable scalar delta.
  class ActivityEventRecordResolver
    RECORD_AFTER_HANDLERS = {
      'create' => :created_record_after,
      'update' => :updated_record_after
    }.freeze
    private_constant :RECORD_AFTER_HANDLERS

    #: (?record_transition: untyped) -> void
    def initialize(record_transition: nil)
      @record_transition = record_transition
    end

    #: (untyped) -> untyped
    def record_after(version)
      return if version.event.to_s == 'destroy'

      changed_record = changed_record_after(version)
      return changed_record if changed_record

      successor = version.next
      record = successor&.reify(dup: true)
      return record if record

      model_class = Endpoint.model_class(version)
      criteria = { model_class.primary_key => version.item_id } #: Hash[untyped, untyped]
      model_class.unscoped.find_by(criteria)
    end

    #: (untyped) -> ActivitySnapshotDelta?
    def snapshot_delta(version)
      return unless version.event.to_s == 'update' && version.object

      transition = @record_transition&.call(version)
      return unless transition

      ActivitySnapshotDelta.new(
        before_attributes: transition.fetch(0),
        after_attributes: transition.fetch(1)
      )
    end

    #: (untyped) -> untyped
    def changed_record_after(version)
      handler = RECORD_AFTER_HANDLERS[version.event.to_s]
      send(handler, version) if handler
    end

    #: (untyped) -> untyped
    def created_record_after(version)
      model_class = Endpoint.model_class(version)
      changes = deserialized_changeset(version, model_class)
      return unless changes.respond_to?(:each) && !changes.empty?

      model_class.new(after_attributes(changes, model_class))
    end

    #: (untyped) -> untyped
    def updated_record_after(version)
      record = version.reify(dup: true)
      changes = deserialized_changeset(version, record&.class)
      apply_changes(record, changes)
    end

    # Mirrors PaperTrail's changeset deserialization without resolving
    # +version.item+, which would issue one live-record query per event.
    #: (untyped, untyped) -> untyped
    def deserialized_changeset(version, model_class)
      return unless model_class && version.class.column_names.include?('object_changes')

      paper_trail = Object.const_get(:PaperTrail) #: untyped
      adapter = paper_trail.config.object_changes_adapter
      return adapter.load_changeset(version) if adapter.respond_to?(:load_changeset)

      standard_changeset(paper_trail, version, model_class)
    end

    private

    # @rbs @record_transition: untyped

    #: (untyped, untyped) -> Hash[untyped, untyped]
    def after_attributes(changes, model_class)
      names = model_class.attribute_names
      attributes = {} #: Hash[untyped, untyped]
      changes.each do |name, values|
        next unless names.include?(name.to_s)

        attributes[name] = values.last
      end
      attributes
    end

    #: (untyped, untyped) -> untyped
    def apply_changes(record, changes)
      return unless record && changes.respond_to?(:each) && !changes.empty?

      changes.each do |name, values|
        next unless record.has_attribute?(name) && values.respond_to?(:last)

        record[name] = values.last
      end
      record
    end

    #: (untyped, untyped, untyped) -> untyped
    def standard_changeset(paper_trail, version, model_class)
      raw_changes = version.send(:object_changes_deserialized)
      active_support = Object.const_get(:ActiveSupport) #: untyped
      changes = active_support.const_get(:HashWithIndifferentAccess).new(raw_changes)
      serializers = paper_trail.const_get(:AttributeSerializers)
      serializers.const_get(:ObjectChangesAttribute).new(model_class).deserialize(changes)
      changes
    end
  end
end
