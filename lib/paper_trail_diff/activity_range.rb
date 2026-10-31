# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Tests activity versions against a historical-version or wall-clock range end.
  class ActivityRange
    attr_reader :start_time #: untyped
    attr_reader :end_time #: untyped

    #: (untyped, untyped) -> void
    def initialize(start_boundary, end_boundary)
      @end_boundary = end_boundary
      @start_key = if Endpoint.version?(start_boundary)
                     Support.chronological_version_key(start_boundary)
                   end
      @start_time = Endpoint.version?(start_boundary) ? start_boundary.created_at : start_boundary
      # A time has no transaction.
      @opening_transaction = ActivityTransactionGroups.transaction_key(start_boundary)
      @end_time = Endpoint.version?(end_boundary) ? end_boundary.created_at : end_boundary
      @end_key = if Endpoint.version?(end_boundary)
                   Support.chronological_version_key(end_boundary)
                 end
    end

    #: (untyped) -> bool
    def include?(version)
      key = Support.chronological_version_key(version)
      after_start?(version, key) && before_end?(version, key)
    end

    # Narrows an Active Record version relation by timestamp, and to the
    # start's transaction. Exact tie-breaking remains in #include? so this
    # works for integer, UUID, and custom version IDs.
    #: (untyped) -> untyped
    def scope(relation)
      in_time = relation.where(created_at: @start_time..end_time)
      opening = @opening_transaction
      return in_time unless opening

      in_time.or(relation.where(transaction_id: opening.last))
    end

    #: () -> bool
    def current_end?
      !Endpoint.version?(@end_boundary)
    end

    # Whether the state a version recorded after its change held inside the
    # range. A range ending at a version ends at the state before it, so the
    # change that version records is past the end, unlike #include?.
    #: (untyped, untyped) -> bool
    def recorded_before_end?(created_at, id)
      end_key = @end_key
      return created_at <= @end_boundary unless end_key

      comparison = Support.version_key(created_at, id) <=> end_key
      raise ConfigurationError, 'versions have incomparable timestamps' unless comparison

      comparison.negative?
    end

    private

    # @rbs @end_boundary: untyped
    # @rbs @start_key: Array[untyped]?
    # @rbs @start_time: untyped
    # @rbs @end_key: Array[untyped]?
    # @rbs @opening_transaction: Array[untyped]?

    # A range starting at a version starts before that version's transaction,
    # where PT-AT reads its associations. A version saved earlier in it, such
    # as the child update behind a `touch: true` parent version, is a change
    # inside the range.
    #: (untyped, Array[untyped]) -> bool
    def after_start?(version, key)
      opening = @opening_transaction
      return true if opening && ActivityTransactionGroups.transaction_key(version) == opening

      start_key = @start_key
      return key_before_or_equal?(start_key, key) if start_key

      version.created_at >= @start_time
    end

    #: (untyped, Array[untyped]) -> bool
    def before_end?(version, key)
      end_key = @end_key
      return key_before_or_equal?(key, end_key) if end_key

      version.created_at <= @end_boundary
    end

    #: (Array[untyped], Array[untyped]) -> bool
    def key_before_or_equal?(left, right)
      comparison = left <=> right
      raise ConfigurationError, 'versions have incomparable timestamps' unless comparison

      comparison <= 0
    end
  end
end
