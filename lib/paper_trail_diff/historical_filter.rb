# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects recorded pre-event states with an explicit ceiling on version loading.
  class HistoricalFilter
    DEFAULT_VERSION_LIMIT = 10_000
    CANDIDATE_BATCH = 250

    #: (untyped, predicate: untyped, time_range: TimeRange?, limit: Integer, max_versions: Integer) -> void
    def initialize(model, predicate:, time_range:, limit:, max_versions:)
      @model = model
      @predicate = validate_predicate(predicate)
      @time_range = time_range
      @limit = limit
      @max_versions = validate_budget(max_versions)
      @loaded = 0
      @state_loader = PreparedVersionStateLoader.new
    end

    #: (Array[String]) -> Array[String]
    def call(candidates)
      matched = [] #: Array[String]
      candidates.each_slice(CANDIDATE_BATCH) do |slice|
        versions = candidate_versions(slice)
        slice.each do |id|
          next unless versions.fetch(id, []).any? { |version| matches?(version) }

          matched << id
          reject_root_limit! if matched.length > @limit
        end
      end
      matched
    end

    private

    # @rbs @model: untyped
    # @rbs @predicate: untyped
    # @rbs @time_range: TimeRange?
    # @rbs @limit: Integer
    # @rbs @max_versions: Integer
    # @rbs @loaded: Integer
    # @rbs @state_loader: PreparedVersionStateLoader

    #: (untyped) -> untyped
    def validate_predicate(predicate)
      return predicate if predicate.respond_to?(:call)
      unless predicate.is_a?(Hash)
        raise ConfigurationError, 'historical_filter: must respond to call or be an attribute hash'
      end

      attributes = predicate.transform_keys(&:to_s)
      unknown = attributes.keys - @model.attribute_names
      if unknown.any?
        raise ConfigurationError,
              "unknown historical attributes: #{unknown.join(', ')}"
      end

      Support.immutable_copy(attributes)
    end

    #: (untyped) -> Integer
    def validate_budget(value)
      return value if value.is_a?(Integer) && value.positive?

      raise ConfigurationError, 'max_filter_versions: must be a positive Integer'
    end

    #: (Array[String]) -> Hash[String, Array[untyped]]
    def candidate_versions(ids)
      relation = @model.paper_trail.version_class.where(item_type: @model.base_class.name,
                                                        item_id: ids)
      range = @time_range
      relation = range.scope(relation) if range
      versions = relation.reorder(created_at: :asc, id: :asc)
                         .limit(@max_versions - @loaded + 1).to_a
      account_versions!(versions.length)
      versions.group_by { |version| version.item_id.to_s }
    end

    #: (Integer) -> void
    def account_versions!(count)
      @loaded += count
      return unless @loaded > @max_versions

      raise FilterLimitExceededError,
            "historical_filter: exceeds max_filter_versions: #{@max_versions}; " \
            'narrow the window or explicitly increase the version budget'
    end

    #: (untyped) -> bool
    def matches?(version)
      if @predicate.is_a?(Hash)
        return false unless version.object

        return attributes_match?(version)
      end

      state = version.reify(dup: true)
      !!(state && @predicate.call(state))
    end

    #: (untyped) -> bool
    def attributes_match?(version)
      state = @state_loader.call(version)
      unless state
        raise ConfigurationError,
              'historical_filter: cannot read recorded attributes directly; use a bounded callable'
      end

      @predicate.all? do |name, expected|
        unless state.attributes.key?(name)
          raise ConfigurationError,
                "historical_filter: #{name} was not recorded in version #{version.id}"
        end

        state.model_class.type_for_attribute(name).cast(state.attributes.fetch(name)) == expected
      end
    end

    #: () -> void
    def reject_root_limit!
      raise BatchLimitExceededError,
            "historical_filter: matched more than #{@limit} roots; narrow the window " \
            'or the filter, or raise limit: to the population you intend to analyze'
    end
  end
end
