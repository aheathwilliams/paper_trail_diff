# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reads values in the form JSON history gives them back.
  #
  # A `json` or `jsonb` object column stores a record's attributes as they
  # are, without PaperTrail's attribute serializer, so a `serialize`d value
  # comes back as JSON writes it: keys as strings, and dates, times and
  # symbols inside it as strings, which its type does not cast back.
  # PaperTrail's JSON serializer stores a binary value as `{"value" => bytes}`,
  # which its type does not cast back either. Compared as they are, the live
  # row and every version would differ though nothing was edited. So every
  # side is read in one form: a `serialize`d value as JSON writes it, and a
  # binary value as its bytes. Both leave a value read from history as it is.
  module StoredJsonValues
    BINARY_TYPE = 'ActiveModel::Type::Binary'
    BINARY_KEYS = ['value'].freeze
    private_constant :BINARY_TYPE, :BINARY_KEYS

    @typed = {} #: Hash[[untyped, String], Array[String]]

    # For a model whose history is JSON, which StoredTimePrecision.digits
    # tells: a `json` or `jsonb` object column, or the JSON serializer.
    #: (untyped, Hash[untyped, untyped]) -> Hash[untyped, untyped]
    def self.apply(model_class, attributes)
      if StoredTimePrecision.json_column?(model_class.paper_trail.version_class, 'object')
        convert(model_class, attributes, Support::SERIALIZED_TYPE, &:as_json)
      else
        convert(model_class, attributes, BINARY_TYPE) { |value| bytes(value) }
      end
    end

    # The attributes with the value of each of this type converted. An
    # adapter's type can be a subclass, as PostgreSQL's `bytea` is of binary.
    #: (untyped, Hash[untyped, untyped], String) { (untyped) -> untyped } -> Hash[untyped, untyped]
    def self.convert(model_class, attributes, type_name)
      names = typed(model_class, type_name).select { |name| attributes.key?(name) }
      return attributes if names.empty?

      converted = attributes.dup
      names.each { |name| converted[name] = yield(attributes.fetch(name)) }
      converted
    end
    private_class_method :convert

    # The names of the model's attributes of this type, which a model keeps
    # as it was defined, as TimeOfDay.columns does.
    #: (untyped, String) -> Array[String]
    def self.typed(model_class, type_name)
      @typed.fetch([model_class, type_name]) do |key|
        type = Support.constant(type_name)
        @typed[key] = model_class.attribute_types.filter_map do |name, attribute_type|
          name if attribute_type.is_a?(type)
        end.freeze
      end
    end
    private_class_method :typed

    #: (untyped) -> untyped
    def self.bytes(value)
      return value unless value.instance_of?(Hash) && value.keys == BINARY_KEYS

      value.fetch('value').b
    end
    private_class_method :bytes
  end
end
