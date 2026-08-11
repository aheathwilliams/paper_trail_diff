# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Applies a caller's version filter to a range, naming which of its versions
  # count as selected mutations. The unfiltered versions stay available to the
  # caller, because the one that reveals the last selected mutation is drawn
  # from them.
  class VersionScopeFilter
    #: (untyped) -> void
    def initialize(scope)
      @scope = validated(scope)
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def call(relation, in_range)
      scope = @scope
      return in_range unless scope

      # A narrowed relation is the expected return. Active Support also gives
      # `pluck` to plain enumerables, so an array of versions works too.
      chosen = Set.new(scope.call(relation).pluck(:id))
      in_range.select { |version| chosen.include?(version.id) }
    end

    private

    # @rbs @scope: untyped

    #: (untyped) -> untyped
    def validated(scope)
      return scope if scope.nil? || scope.respond_to?(:call)

      raise ConfigurationError, 'version_scope: must respond to call'
    end
  end
end
