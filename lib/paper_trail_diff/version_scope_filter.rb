# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Applies a caller's version filter to a range, naming which of its versions
  # count as selected mutations. The unfiltered versions stay available to the
  # caller, because the one that reveals the last selected mutation is drawn
  # from them.
  class VersionScopeFilter
    # The filter, checked once where it is given: a callable that takes the
    # version relation, and that wherever it is called returns it narrowed,
    # or an array of its versions. A relation on another table would be read
    # for its ids all the same, and choose the versions that happen to share
    # them.
    #: (untyped) -> untyped
    def self.checked(scope)
      return if scope.nil?
      raise ConfigurationError, 'version_scope: must respond to call' unless scope.respond_to?(:call)
      unless takes_relation?(scope)
        raise ConfigurationError, 'version_scope: must take the version relation as its one argument'
      end

      ->(relation) { narrowed(scope.call(relation), relation) }
    end

    # A proc that is not a lambda takes any number of arguments.
    #: (untyped) -> bool
    def self.takes_relation?(scope)
      return true if scope.is_a?(Proc) && !scope.lambda?

      arity = (scope.respond_to?(:arity) ? scope : scope.method(:call)).arity
      arity.negative? ? arity >= -2 : arity == 1
    end
    private_class_method :takes_relation?

    #: (untyped, untyped) -> untyped
    def self.narrowed(result, relation)
      return result if versions?(result)
      unless result.respond_to?(:klass) && result.respond_to?(:table_name)
        raise ConfigurationError, 'version_scope: must return the relation it is given, narrowed, ' \
                                  "or an array of its versions; it returned #{result.class}"
      end

      given = relation.table_name
      returned = result.table_name
      return result if returned == given

      raise ConfigurationError, 'version_scope: must return the relation it is given, ' \
                                "narrowed; it returned one on #{returned}, not #{given}"
    end
    private_class_method :narrowed

    #: (untyped) -> bool
    def self.versions?(result)
      result.instance_of?(Array) && result.all? { |version| Endpoint.version?(version) }
    end
    private_class_method :versions?

    #: (untyped) -> void
    def initialize(scope)
      @scope = scope
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def call(relation, in_range)
      chosen = chosen_ids(relation)
      return in_range unless chosen

      in_range.select { |version| chosen.include?(version.id) }
    end

    # The ids of the versions the scope keeps, or nil when there is no scope.
    #: (untyped) -> Set[untyped]?
    def chosen_ids(relation)
      scope = @scope
      return unless scope

      # A narrowed relation is the expected return. Active Support also gives
      # `pluck` to plain enumerables, so an array of versions works too.
      Set.new(scope.call(relation).pluck(:id))
    end

    # @rbs @scope: untyped
  end
end
