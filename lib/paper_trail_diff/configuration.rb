# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # An immutable, bounded tree built from explicit association paths.
  class AssociationTree
    attr_reader :children #: Hash[String, AssociationTree]

    class << self
      #: (untyped) -> AssociationTree
      def build(values)
        unless valid_values?(values)
          raise ConfigurationError, 'associations: must be an array of strings or symbols'
        end

        tree = {} #: Hash[String, untyped]
        values.each { |value| add_path(tree, value.to_s) }
        from_hash(tree)
      end

      private

      #: (Hash[String, untyped], String) -> void
      def add_path(tree, path)
        segments = path.split('.', -1)
        if segments.empty? || segments.any?(&:empty?) || path == '$'
          raise ConfigurationError, "invalid association path: #{path.inspect}"
        end

        segments.inject(tree) do |branch, segment|
          branch[segment] ||= {} #: Hash[String, untyped]
        end
      end

      #: (Hash[String, untyped]) -> AssociationTree
      def from_hash(tree)
        children = tree.sort.to_h do |name, branch|
          [name, from_hash(branch)]
        end
        new(children)
      end

      #: (untyped) -> bool
      def valid_values?(values)
        values.is_a?(Array) && values.all? do |value|
          value.is_a?(String) || value.is_a?(Symbol)
        end
      end
    end

    #: (Hash[String, AssociationTree]) -> void
    def initialize(children)
      @children = children.dup.freeze
      freeze
    end

    #: () -> bool
    def empty?
      children.empty?
    end

    #: (String | Symbol) -> AssociationTree?
    def child(name)
      children[name.to_s]
    end

    #: (Array[String]) -> AssociationTree
    def select(names)
      self.class.new(children.slice(*names))
    end

    #: (?prefix: String) -> Array[String]
    def paths(prefix: '')
      children.flat_map do |name, subtree|
        path = prefix.empty? ? name : "#{prefix}.#{name}"
        [path, *subtree.paths(prefix: path)]
      end.freeze
    end
  end

  # Immutable rules for globally and path-specifically excluded attributes.
  class IgnorePolicy
    ROOT_PATH = '$'
    VALID_KEYS = %w[all paths].freeze
    private_constant :VALID_KEYS

    class << self
      #: (untyped, association_paths: Array[String]) -> IgnorePolicy
      def build(value, association_paths:)
        return new(all: normalize_names(value, context: 'ignore'), paths: {}) if value.is_a?(Array)

        unless value.is_a?(Hash)
          raise ConfigurationError, 'ignore: must be an array or a hash with all: and paths:'
        end

        options = normalize_options(value)
        empty_paths = {} #: Hash[untyped, untyped]
        new(
          all: normalize_names(options.fetch('all', []), context: 'ignore[:all]'),
          paths: normalize_paths(options.fetch('paths', empty_paths), association_paths)
        )
      end

      private

      #: (Hash[untyped, untyped]) -> Hash[String, untyped]
      def normalize_options(value)
        options = {} #: Hash[String, untyped]
        value.each do |key, item|
          name = key.to_s
          unless VALID_KEYS.include?(name) && !options.key?(name)
            raise ConfigurationError, "unknown or duplicate ignore option: #{key.inspect}"
          end

          options[name] = item
        end
        options
      end

      #: (untyped, Array[String]) -> Hash[String, Array[String]]
      def normalize_paths(value, association_paths)
        raise ConfigurationError, 'ignore[:paths]: must be a hash' unless value.is_a?(Hash)

        allowed_paths = [ROOT_PATH, *association_paths]
        paths = {} #: Hash[String, Array[String]]
        value.each do |path, names|
          add_path_rule(paths, path, names, allowed_paths)
        end
        paths.sort.to_h.freeze
      end

      #: (Hash[String, Array[String]], untyped, untyped, Array[String]) -> void
      def add_path_rule(paths, path, names, allowed_paths)
        normalized_path = path.to_s
        unless allowed_paths.include?(normalized_path) && !paths.key?(normalized_path)
          raise ConfigurationError, "unknown or duplicate ignore path: #{path.inspect}"
        end

        context = "ignore[:paths][#{normalized_path.inspect}]"
        paths[normalized_path] = normalize_names(names, context: context)
      end

      #: (untyped, context: String) -> Array[String]
      def normalize_names(values, context:)
        valid = values.is_a?(Array) && values.all? do |value|
          value.is_a?(String) || value.is_a?(Symbol)
        end
        raise ConfigurationError, "#{context}: must be an array of strings or symbols" unless valid

        values.map(&:to_s).uniq.sort.freeze
      end
    end

    attr_reader :all #: Array[String]
    attr_reader :paths #: Hash[String, Array[String]]

    #: (all: Array[String], paths: Hash[String, Array[String]]) -> void
    def initialize(all:, paths:)
      @all = all.dup.freeze
      @paths = paths.dup.freeze
      freeze
    end

    #: (String) -> Array[String]
    def attributes_for(path)
      external_path = path.empty? ? ROOT_PATH : path
      (all + paths.fetch(external_path, [])).uniq.freeze
    end
  end
end
