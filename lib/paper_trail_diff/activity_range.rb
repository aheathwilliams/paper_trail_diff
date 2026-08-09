# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Tests activity versions against a historical-version or wall-clock range end.
  class ActivityRange
    #: (untyped, untyped) -> void
    def initialize(start_version, end_boundary)
      @start_version = start_version
      @end_boundary = end_boundary
      @start_key = Support.chronological_version_key(start_version)
      @end_key = if Endpoint.version?(end_boundary)
                   Support.chronological_version_key(end_boundary)
                 end
    end

    #: (untyped) -> bool
    def include?(version)
      key = Support.chronological_version_key(version)
      key_before_or_equal?(@start_key, key) && before_end?(version, key)
    end

    # Narrows an Active Record version relation by timestamp. Exact tie-breaking
    # remains in #include? so this works for integer, UUID, and custom version IDs.
    #: (untyped) -> untyped
    def scope(relation)
      relation.where(created_at: @start_version.created_at..end_time)
    end

    private

    # @rbs @start_version: untyped
    # @rbs @end_boundary: untyped
    # @rbs @start_key: Array[untyped]
    # @rbs @end_key: Array[untyped]?

    #: (untyped, Array[untyped]) -> bool
    def before_end?(version, key)
      end_key = @end_key
      return key_before_or_equal?(key, end_key) if end_key

      version.created_at <= @end_boundary
    end

    #: () -> untyped
    def end_time
      Endpoint.version?(@end_boundary) ? @end_boundary.created_at : @end_boundary
    end

    #: (Array[untyped], Array[untyped]) -> bool
    def key_before_or_equal?(left, right)
      comparison = left <=> right
      raise ConfigurationError, 'versions have incomparable timestamps' unless comparison

      comparison <= 0
    end
  end
end
