# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects roots by the values they held at any point in the window, with an
  # explicit ceiling on version loading.
  #
  # A version records the state *before* its own change, so the versions in
  # the window supply the state at its start and after every change but the
  # last. The state after the last change lives in the first version after
  # the window, or in the live row when nothing follows; a destroy leaves none.
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

    # More matches than the limit raise, unless the caller does not count
    # them: candidates it only lists, such as deleted roots.
    #: (Array[String], ?counted: bool) -> Array[String]
    def call(candidates, counted: true)
      matched = [] #: Array[String]
      candidates.each_slice(CANDIDATE_BATCH) do |slice|
        versions = candidate_versions(slice)
        closing = closing_states(slice, versions)
        slice.each do |id|
          next unless held?(versions.fetch(id, []), closing[id])

          matched << id
          reject_root_limit! if counted && matched.length > @limit
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

      attributes.to_h { |name, value| [name, cast(name, value)] }
    end

    # Expected and recorded values compare as the attribute casts them, as
    # `where` reads its values: an enum's symbol names its stored value, and a
    # `json` or `jsonb` version column, which PaperTrail does not cast, holds
    # dates and times as strings. Casting also copies a mutable value, so the
    # filter keeps its own.
    #: (String, untyped) -> untyped
    def cast(name, value)
      @model.type_for_attribute(name).cast(value)
    end

    #: (untyped) -> Integer
    def validate_budget(value)
      return value if value.instance_of?(Integer) && value.positive?

      raise ConfigurationError, 'max_filter_versions: must be a positive Integer'
    end

    #: (Array[String]) -> Hash[String, Array[untyped]]
    def candidate_versions(ids)
      relation = VersionQuery.for_items(@model, ids)
      range = @time_range
      relation = range.scope(relation) if range
      # One past the remaining budget is enough to know it was exceeded.
      versions = VersionQuery.chronological(relation).limit(@max_versions - @loaded + 1)
      account_versions!(versions.length)
      versions.group_by { |version| version.item_id.to_s }
    end

    #: (Array[untyped], untyped) -> boolish
    def held?(versions, closing)
      return true if versions.any? { |version| matches?(version) }
      return false unless closing

      Endpoint.version?(closing) ? matches?(closing) : record_matches?(closing)
    end

    # What each candidate held after its last change in the window.
    #: (Array[String], Hash[String, Array[untyped]]) -> Hash[String, untyped]
    def closing_states(ids, versions)
      open = ids.reject { |id| versions.fetch(id, []).last&.event == 'destroy' }
      trailing = trailing_versions(open)
      trailing.merge(live_records(open - trailing.keys))
    end

    #: (Array[String]) -> Hash[String, untyped]
    def trailing_versions(ids)
      range = @time_range
      return {} unless range

      trailing = range.first_trailing_versions(VersionQuery.for_items(@model, ids))
      account_versions!(trailing.length)
      trailing
    end

    #: (Array[String]) -> Hash[String, untyped]
    def live_records(ids)
      @model.unscoped.where(@model.primary_key => ids).to_h { |record| [record.id.to_s, record] }
    end

    #: (untyped) -> boolish
    def record_matches?(record)
      return @predicate.call(record) unless @predicate.instance_of?(Hash)

      @predicate.all? { |name, expected| record.attributes.fetch(name) == expected }
    end

    #: (Integer) -> void
    def account_versions!(count)
      @loaded += count
      return unless @loaded > @max_versions

      raise FilterLimitExceededError,
            "historical_filter: exceeds max_filter_versions: #{@max_versions}; " \
            'narrow the window or explicitly increase the version budget'
    end

    #: (untyped) -> boolish
    def matches?(version)
      if @predicate.instance_of?(Hash)
        return false unless version.object

        return attributes_match?(version)
      end

      state = version.reify(dup: true)
      state && @predicate.call(state)
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

        cast(name, state.attributes.fetch(name)) == expected
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
