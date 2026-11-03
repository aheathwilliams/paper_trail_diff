# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reconstructs an event's post-change record or immutable scalar delta.
  class ActivityEventRecordResolver
    #: (?record_transition: untyped, ?prepared_record_after: untyped) -> void
    def initialize(record_transition: nil, prepared_record_after: nil)
      @record_transition = record_transition
      @prepared_record_after = prepared_record_after
    end

    # The record as the version left it: the state recorded next, which holds
    # any change saved after the version without one of its own. Prepared
    # history answers without a query; without it, the next version or the
    # live row does.
    #: (untyped, ?direct: bool) -> untyped
    def record_after(version, direct: false)
      return if version.event.to_s == 'destroy'

      if direct
        handled, state = @prepared_record_after&.call(version, direct: true)
        return state if handled
      end

      handled, prepared = @prepared_record_after&.call(version)
      return prepared if handled

      recorded_after(version)
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

    #: (untyped) -> untyped
    def recorded_after(version)
      successor = version.next
      record = successor && Support.reify(successor, dup: true)
      return record if record

      model_class = Endpoint.model_class(version)
      criteria = { model_class.primary_key => version.item_id } #: Hash[untyped, untyped]
      model_class.unscoped.find_by(criteria)
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

    #: (untyped, untyped, untyped) -> untyped
    def standard_changeset(paper_trail, version, model_class)
      raw_changes = Support.decodable(version.send(:object_changes_deserialized))
      active_support = Object.const_get(:ActiveSupport) #: untyped
      changes = active_support.const_get(:HashWithIndifferentAccess).new(raw_changes)
      serializers = paper_trail.const_get(:AttributeSerializers)
      serializers.const_get(:ObjectChangesAttribute).new(model_class).deserialize(changes)
      changes
    end
  end
end
