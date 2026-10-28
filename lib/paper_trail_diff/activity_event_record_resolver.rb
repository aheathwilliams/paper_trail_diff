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

    #: (?record_transition: untyped, ?prepared_record_after: untyped) -> void
    def initialize(record_transition: nil, prepared_record_after: nil)
      @record_transition = record_transition
      @prepared_record_after = prepared_record_after
      @direct_loader = DirectRecordStateLoader.new
    end

    #: (untyped, ?direct: bool) -> untyped
    def record_after(version, direct: false)
      return if version.event.to_s == 'destroy'

      if direct
        handled, state = direct_after(version)
        return state if handled
      end

      handled, prepared = @prepared_record_after&.call(version)
      return prepared if handled

      fallback_record_after(version)
    end

    #: (untyped) -> [bool, untyped]
    def direct_after(version)
      handled, state = @prepared_record_after&.call(version, direct: true)
      return [true, state] if handled

      state = direct_record_after(version)
      [!state.nil?, state]
    end

    #: (untyped) -> untyped
    def fallback_record_after(version)
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
      return unless model_class
      unless version.class.column_names.include?('object_changes')
        return prepared_changeset(version)
      end

      paper_trail = Object.const_get(:PaperTrail) #: untyped
      adapter = paper_trail.config.object_changes_adapter
      return adapter.load_changeset(version) if adapter.respond_to?(:load_changeset)

      changes = standard_changeset(paper_trail, version, model_class)
      changes.empty? ? prepared_changeset(version) : changes
    end

    private

    # @rbs @record_transition: untyped
    # @rbs @prepared_record_after: untyped
    # @rbs @direct_loader: DirectRecordStateLoader

    #: (untyped) -> PreparedRecordState?
    def direct_record_after(version)
      model = Endpoint.model_class(version)
      changes = deserialized_changeset(version, model)
      return unless changes.respond_to?(:each) && !changes.empty?

      before = if version.object
                 @direct_loader.call(version)
               else
                 PreparedRecordState.from_attributes(
                   model, {}
                 )
               end
      return unless before

      attributes = before.attributes.merge(after_attributes(changes, model))
      @direct_loader.complete(PreparedRecordState.from_attributes(model, attributes))
    end

    #: (untyped) -> untyped
    def prepared_changeset(version)
      transition = @record_transition&.call(version)
      return {} unless transition

      before, after = transition
      (before.keys | after.keys).filter_map do |name|
        [name, [before[name], after[name]]] unless before[name] == after[name]
      end.to_h
    end

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
