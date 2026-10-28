# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Completes plain recorded state without invoking model initialization or writers.
  # Decline model behavior whose values require an actual ActiveRecord instance.
  class DirectRecordStateLoader
    #: () -> void
    def initialize
      @loader = PreparedVersionStateLoader.new
      @supported = {} #: Hash[untyped, bool]
      @defaults = {} #: Hash[untyped, Hash[untyped, untyped]]
    end

    #: (untyped) -> PreparedRecordState?
    def call(version)
      state = @loader.call(version)
      complete(state) if state
    end

    #: (PreparedRecordState) -> PreparedRecordState?
    def complete(state)
      model = state.model_class
      return unless supported?(model)

      defaults = @defaults[model] ||= model.column_defaults
      attributes = defaults.merge(state.attributes).to_h do |name, value|
        [name, model.type_for_attribute(name).cast(value)]
      end
      PreparedRecordState.from_attributes(model, attributes)
    end

    private

    # @rbs @loader: PreparedVersionStateLoader
    # @rbs @supported: Hash[untyped, bool]
    # @rbs @defaults: Hash[untyped, Hash[untyped, untyped]]

    #: (untyped) -> bool
    def supported?(model)
      return @supported[model] if @supported.key?(model)

      @supported[model] = plain_model?(model) && plain_attributes?(model)
    end

    #: (untyped) -> bool
    def plain_model?(model)
      !model.primary_key.is_a?(Array) && !model.default_scopes? &&
        model._initialize_callbacks.empty? &&
        %i[initialize attributes []= write_attribute id].all? do |name|
          framework_class?(model.instance_method(name).owner)
        end
    end

    #: (untyped) -> bool
    def plain_attributes?(model)
      return false if encrypted?(model)
      return false unless model.attribute_types.keys.sort == model.column_names.sort
      return false if application_defaults?(model)

      model.attribute_types.values.all? { |type| framework_class?(type.class) }
    end

    #: (untyped) -> bool
    def application_defaults?(model)
      model._default_attributes.each_value.any? do |attribute|
        attribute.class.name.to_s.end_with?('UserProvidedDefault')
      end
    end

    #: (untyped) -> bool
    def encrypted?(model)
      !!(model.respond_to?(:encrypted_attributes) && model.encrypted_attributes&.any?)
    end

    #: (untyped) -> bool
    def framework_class?(value)
      value.name.to_s.start_with?('ActiveRecord::', 'ActiveModel::')
    end
  end
end
