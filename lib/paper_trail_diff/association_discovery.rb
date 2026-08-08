# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # One discoverable ActiveRecord association path.
  class AssociationDescriptor
    attr_reader :path #: String
    attr_reader :kind #: Symbol
    attr_reader :target_type #: String?
    attr_reader :through #: String?
    attr_reader :polymorphic #: bool
    attr_reader :cycle #: bool

    #: (path: String, kind: Symbol, target_type: String?, ?through: String?, ?flags: Array[Symbol]) -> void
    def initialize(path:, kind:, target_type:, through: nil, flags: [])
      @path = Support.immutable_copy(path)
      @kind = kind
      @target_type = Support.immutable_copy(target_type)
      @through = Support.immutable_copy(through)
      @polymorphic = flags.include?(:polymorphic)
      @cycle = flags.include?(:cycle)
      freeze
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        path: path,
        kind: kind,
        target_type: target_type,
        through: through,
        polymorphic: polymorphic,
        cycle: cycle
      }
    end
  end

  # Discovers finite, supported association paths for configuration UIs.
  class AssociationDiscovery
    #: (untyped, max_depth: Integer) -> void
    def initialize(model_or_record, max_depth:)
      unless max_depth.is_a?(Integer) && max_depth.positive?
        raise ConfigurationError, 'max_depth: must be a positive integer'
      end

      @model_class = model_or_record.is_a?(Class) ? model_or_record : model_or_record.class
      @max_depth = max_depth
      return if @model_class.respond_to?(:reflect_on_all_associations)

      raise ConfigurationError, 'expected an ActiveRecord model class or record'
    end

    #: () -> Array[AssociationDescriptor]
    def call
      discover(@model_class, prefix: '', ancestry: [@model_class], depth: 1).freeze
    end

    private

    # @rbs @model_class: untyped
    # @rbs @max_depth: Integer

    #: (untyped, prefix: String, ancestry: Array[untyped], depth: Integer) -> Array[AssociationDescriptor]
    def discover(model_class, prefix:, ancestry:, depth:)
      supported_reflections(model_class).flat_map do |reflection|
        describe_and_descend(reflection, prefix: prefix, ancestry: ancestry, depth: depth)
      end
    end

    #: (untyped, prefix: String, ancestry: Array[untyped], depth: Integer) -> Array[AssociationDescriptor]
    def describe_and_descend(reflection, prefix:, ancestry:, depth:)
      path = association_path(prefix, reflection.name.to_s)
      target_class = reflection_target(reflection)
      cycle = target_class ? ancestry.include?(target_class) : false
      descriptor = descriptor_for(reflection, path, target_class, cycle)
      return [descriptor] unless target_class && !cycle && depth < @max_depth

      descendants = discover(
        target_class,
        prefix: path,
        ancestry: [*ancestry, target_class],
        depth: depth + 1
      )
      [descriptor, *descendants]
    end

    #: (untyped, String, untyped, bool) -> AssociationDescriptor
    def descriptor_for(reflection, path, target_class, cycle)
      flags = [] #: Array[Symbol]
      flags << :polymorphic if reflection.polymorphic?
      flags << :cycle if cycle
      AssociationDescriptor.new(
        path: path,
        kind: reflection.macro,
        target_type: target_class&.name || reflection_target_name(reflection),
        through: reflection.options[:through]&.to_s,
        flags: flags
      )
    end

    #: (untyped) -> Array[untyped]
    def supported_reflections(model_class)
      model_class.reflect_on_all_associations
                 .select { |reflection| SUPPORTED_ASSOCIATION_MACROS.include?(reflection.macro) }
                 .reject { |reflection| paper_trail_versions?(model_class, reflection) }
                 .sort_by { |reflection| reflection.name.to_s }
    end

    #: (untyped, untyped) -> bool
    def paper_trail_versions?(model_class, reflection)
      model_class.respond_to?(:versions_association_name) &&
        reflection.name.to_s == model_class.versions_association_name.to_s
    end

    #: (untyped) -> untyped
    def reflection_target(reflection)
      reflection.klass unless reflection.polymorphic?
    rescue NameError
      nil
    end

    #: (untyped) -> String?
    def reflection_target_name(reflection)
      reflection.class_name.to_s unless reflection.polymorphic?
    end

    #: (String, String) -> String
    def association_path(prefix, name)
      prefix.empty? ? name : "#{prefix}.#{name}"
    end
  end
end
