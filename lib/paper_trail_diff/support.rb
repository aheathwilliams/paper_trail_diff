# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Internal helpers for isolating and serializing values held by result objects.
  module Support
    module_function

    #: (untyped) -> untyped
    def immutable_copy(value)
      return value if value.frozen?

      case value
      when Hash
        immutable_hash(value)
      when Array
        value.map { |item| immutable_copy(item) }.freeze
      else
        duplicate_and_freeze(value)
      end
    end

    #: (Hash[untyped, untyped]) -> Hash[untyped, untyped]
    def immutable_hash(value)
      copy = {} #: Hash[untyped, untyped]
      value.each do |key, item|
        copy[immutable_copy(key)] = immutable_copy(item)
      end
      copy.freeze
    end
    private_class_method :immutable_hash

    #: (untyped) -> untyped
    def serialize(value)
      case value
      when Hash
        serialized = {} #: Hash[untyped, untyped]
        value.each do |key, item|
          serialized[key] = serialize(item)
        end
        serialized
      when Array
        value.map { |item| serialize(item) }
      else
        paper_trail_diff_value?(value) ? value.to_h : value
      end
    end

    #: (untyped) -> Array[untyped]
    def chronological_version_key(version)
      [version.created_at, version.id.to_s.rjust(32, '0')]
    end

    #: (untyped, untyped) -> Integer
    def compare_versions(left, right)
      chronological_version_key(left) <=> chronological_version_key(right) ||
        raise(ConfigurationError, 'versions have incomparable timestamps')
    end

    #: (String, String) -> String
    def association_path(parent, name)
      parent.empty? ? name : "#{parent}.#{name}"
    end

    #: (untyped) -> untyped
    def duplicate_and_freeze(value)
      value.dup.freeze
    rescue TypeError
      value
    end
    private_class_method :duplicate_and_freeze

    #: (untyped) -> bool
    def paper_trail_diff_value?(value)
      class_name = value.class.name
      class_name&.start_with?('PaperTrailDiff::') && value.respond_to?(:to_h)
    end
    private_class_method :paper_trail_diff_value?
  end
end
