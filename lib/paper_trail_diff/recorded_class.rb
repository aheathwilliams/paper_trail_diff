# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The class a record had at one version, which decides the associations it
  # can have. Without an `item_subtype` column PaperTrail stores only the base
  # class, so an STI subclass is read from the stored inheritance column: the
  # state before the change, or for a create, the value it was created with.
  # A version that stored neither stays on the base class.
  module RecordedClass
    #: (untyped) -> untyped
    def self.for(version)
      model = Endpoint.model_class(version)
      return model unless sti_base?(model)

      type = stored_type(version, model).to_s
      type.empty? ? model : model.sti_class_for(type)
    rescue Support.active_record(:SubclassNotFound)
      raise InvalidEndpointError, "cannot resolve endpoint model: #{type}"
    end

    # The class a version recorded, or a live record's own class.
    #: (untyped) -> untyped
    def self.of_endpoint(endpoint)
      Endpoint.version?(endpoint) ? self.for(endpoint) : endpoint.class
    end

    #: (untyped) -> bool
    def self.sti_base?(model)
      model.base_class == model && model.columns_hash.key?(model.inheritance_column)
    end
    private_class_method :sti_base?

    #: (untyped, untyped) -> untyped
    def self.stored_type(version, model)
      column = model.inheritance_column
      if version.object
        attributes = version.object_deserialized
        return attributes.is_a?(Hash) ? attributes[column] || attributes[column.to_sym] : nil
      end

      changes = ActivityEventRecordResolver.new.deserialized_changeset(version, model)
      values = changes[column] if changes.respond_to?(:key?)
      values.last if values.instance_of?(Array)
    end
    private_class_method :stored_type
  end
end
