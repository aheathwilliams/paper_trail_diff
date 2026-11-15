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
    # Values `where` reads as several.
    SEVERAL = [Array, Range, Set].freeze
    private_constant :SEVERAL

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
    #
    # A `page` is the relation's own, as the matches to skip and to take
    # among candidates given in its order. Matching stops when the page is
    # full, so no history is read past it, and only the page counts toward
    # the limit.
    #: (Array[String], ?counted: bool, ?page: [Integer, Integer]?) -> Array[String]
    def call(candidates, counted: true, page: nil)
      skipped = page ? page.first : 0
      full = page&.sum
      matched = [] #: Array[String]
      each_match(candidates) do |id|
        matched << id
        reject_root_limit! if counted && matched.length - skipped > @limit
        break if matched.length == full
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

    # Each candidate that held a matching state, in the order given, read a
    # batch at a time.
    #: (Array[String]) { (String) -> void } -> void
    def each_match(candidates)
      candidates.each_slice(Support::IDS_PER_STATEMENT) do |slice|
        versions = candidate_versions(slice, @time_range)
        closing = closing_states(slice, versions)
        slice.each { |id| yield id if held?(versions.fetch(id, []), closing[id]) }
      end
    end

    #: (untyped) -> untyped
    def validate_predicate(predicate)
      return predicate if predicate.respond_to?(:call)
      unless predicate.is_a?(Hash)
        raise ConfigurationError, 'historical_filter: must respond to call or be an attribute hash'
      end

      attributes = named_attributes(predicate)
      attributes.to_h { |name, value| [name, expected(name, value)] }
    end

    # The attribute hash by name, each named once and on the model.
    #: (Hash[untyped, untyped]) -> Hash[String, untyped]
    def named_attributes(predicate)
      attributes = predicate.transform_keys(&:to_s)
      if attributes.length < predicate.length
        raise ConfigurationError,
              'historical_filter: names an attribute twice, as a string and a symbol'
      end

      unknown = attributes.keys - @model.attribute_names
      return attributes if unknown.empty?

      raise ConfigurationError, "unknown historical attributes: #{unknown.join(', ')}"
    end

    # `where` reads a list or a range as any of its values, which an
    # equality with one cast value cannot mean, so it is refused unless the
    # attribute itself holds one, as a serialized or an array column does.
    #: (String, untyped) -> untyped
    def expected(name, value)
      cast = stored(name, value)
      return cast unless SEVERAL.any? { |kind| value.is_a?(kind) } && !cast.is_a?(value.class)

      raise ConfigurationError,
            "historical_filter: #{name} takes one value, not #{value.class.name.downcase}; " \
            'use a callable to match any of several'
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

    # A value cast, then read as history can hold it (see StoredValues), so
    # that one filter value means the same in a version and in the live row:
    # JSON history keeps a time to the millisecond, and a column can keep a
    # value less exactly than Ruby does.
    #: (String, untyped) -> untyped
    def stored(name, value)
      StoredValues.apply(@model, { name => cast(name, value) }).fetch(name)
    end

    #: (untyped) -> Integer
    def validate_budget(value)
      return value if value.instance_of?(Integer) && value.positive?

      raise ConfigurationError, 'max_filter_versions: must be a positive Integer'
    end

    #: (Array[String], TimeRange?) -> Hash[String, Array[untyped]]
    def candidate_versions(ids, range)
      relation = VersionQuery.for_items(@model, ids)
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

    # What each candidate held after its last change in the window: the
    # first version past the end, or the live row.
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

      live = StoredValues.apply(@model, record.attributes)
      @predicate.all? { |name, expected| live.fetch(name) == expected }
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

      state = Support.reify(version, dup: true)
      state && @predicate.call(state)
    end

    #: (untyped) -> bool
    def attributes_match?(version)
      recorded = recorded_attributes(version)
      @predicate.all? do |name, expected|
        unless recorded.key?(name)
          raise ConfigurationError,
                "historical_filter: #{name} was not recorded in version #{version.id}"
        end

        stored(name, recorded.fetch(name)) == expected
      end
    end

    # The attributes the version recorded, read as stored where they can be.
    #: (untyped) -> Hash[String, untyped]
    def recorded_attributes(version)
      state = @state_loader.call(version)
      state ? state.attributes : rebuilt_attributes(version)
    end

    # A model whose stored values only a record can read, such as one with an
    # encrypted attribute, or whose version names a column since removed, is
    # rebuilt as PaperTrail rebuilds it. The record also holds attributes the
    # version did not record, which are left out.
    #: (untyped) -> Hash[String, untyped]
    def rebuilt_attributes(version)
      recorded = version.object_deserialized
      record = Support.reify(version, dup: true) if recorded.is_a?(Hash)
      return record.attributes.slice(*recorded.keys) if record

      raise ConfigurationError,
            'historical_filter: cannot read recorded attributes directly; use a bounded callable'
    end

    #: () -> void
    def reject_root_limit!
      raise BatchLimitExceededError,
            "historical_filter: matched more than #{@limit} roots; narrow the window " \
            'or the filter, or raise limit: to the population you intend to analyze'
    end
  end
end
