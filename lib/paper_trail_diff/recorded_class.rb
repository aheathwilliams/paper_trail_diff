# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The class a record had at one version, which decides the associations it
  # can have. Without an `item_subtype` column PaperTrail stores only the base
  # class, so an STI subclass is read from the stored inheritance column: the
  # state before the change, or for a create, the value it was created with.
  # A version that stored neither stays on the base class.
  module RecordedClass
    module_function

    #: (untyped) -> untyped
    def for(version)
      model = Endpoint.model_class(version)
      return model unless sti_base?(model)

      type = stored_type(version, model).to_s
      type.empty? ? model : model.sti_class_for(type)
    rescue StandardError => e
      raise unless subclass_not_found?(e)

      raise InvalidEndpointError, "cannot resolve endpoint model: #{type}", cause: e
    end

    #: (untyped) -> bool
    def sti_base?(model)
      model.base_class == model && model.columns_hash.key?(model.inheritance_column.to_s)
    end
    private_class_method :sti_base?

    #: (untyped, untyped) -> untyped
    def stored_type(version, model)
      column = model.inheritance_column.to_s
      if version.object
        attributes = version.object_deserialized
        return attributes.is_a?(Hash) ? attributes[column] || attributes[column.to_sym] : nil
      end

      changes = ActivityEventRecordResolver.new.deserialized_changeset(version, model)
      values = changes[column] if changes.respond_to?(:key?) && changes.key?(column)
      values.last if values.is_a?(Array)
    end
    private_class_method :stored_type

    #: (StandardError) -> bool
    def subclass_not_found?(error)
      active_record = Object.const_get(:ActiveRecord) #: untyped
      error.is_a?(active_record.const_get(:SubclassNotFound))
    end
    private_class_method :subclass_not_found?
  end
end
