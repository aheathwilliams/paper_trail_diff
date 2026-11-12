# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Applies a caller's version filter to a range, naming which of its versions
  # count as selected mutations. The unfiltered versions stay available to the
  # caller, because the one that reveals the last selected mutation is drawn
  # from them.
  class VersionScopeFilter
    # A filter is a callable that narrows the version relation.
    #: (untyped) -> untyped
    def self.validated(scope)
      return scope if scope.nil? || scope.respond_to?(:call)

      raise ConfigurationError, 'version_scope: must respond to call'
    end

    # The filter, with what it returns checked wherever it is called. A
    # relation on another table would be read for its ids all the same, and
    # choose the versions that happen to share them.
    #: (untyped) -> untyped
    def self.checked(scope)
      return scope unless scope.respond_to?(:call)

      ->(relation) { narrowed(scope.call(relation), relation) }
    end

    #: (untyped, untyped) -> untyped
    def self.narrowed(result, relation)
      return result unless result.respond_to?(:klass)

      given = relation.table_name
      returned = result.table_name
      return result if returned == given

      raise ConfigurationError, 'version_scope: must return the relation it is given, ' \
                                "narrowed; it returned one on #{returned}, not #{given}"
    end
    private_class_method :narrowed

    #: (untyped) -> void
    def initialize(scope)
      @scope = self.class.validated(scope)
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
