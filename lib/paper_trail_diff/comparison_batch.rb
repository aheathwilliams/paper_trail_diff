# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Validates and executes independent comparisons with shared live endpoint loading.
  class ComparisonBatch
    # `history_preparer` prepares roots that have a live endpoint to collect a
    # graph from; `version_history_preparer` prepares roots compared only
    # between versions.
    #: (Array[comparison_input], live_loader: untyped, preparer: untyped, history_preparer: untyped, version_history_preparer: untyped, historical_snapshotter: untyped, live_normalizer: untyped) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      comparisons,
      live_loader:,
      preparer:,
      history_preparer:,
      version_history_preparer:,
      historical_snapshotter:,
      live_normalizer:
    )
      @comparisons = comparisons
      @live_loader = live_loader
      @preparer = preparer
      @history_preparer = history_preparer
      @version_history_preparer = version_history_preparer
      @historical_snapshotter = historical_snapshotter
      @live_normalizer = live_normalizer
    end

    #: () -> comparison_results
    def call
      resolved = BatchBoundaryResolver.new(comparison_pairs).call
      pairs = resolved.reject { |pair| pair.any? { |endpoint| symbolic?(endpoint) } }
      ensure_unique_identities!(resolved)
      results(resolved, prepared_live_snapshots(pairs)).freeze
    end

    private

    # @rbs @comparisons: Array[comparison_input]
    # @rbs @live_loader: untyped
    # @rbs @preparer: untyped
    # @rbs @history_preparer: untyped
    # @rbs @version_history_preparer: untyped
    # @rbs @historical_snapshotter: untyped
    # @rbs @live_normalizer: untyped

    #: (Array[[untyped, untyped]]) -> Hash[identity, RecordSnapshot]
    def prepared_live_snapshots(pairs)
      pairs.each { |from, to| Endpoint.validate_pair!(from, to) }
      prepare_endpoint_classes!(pairs)
      live_records = load_live_records(pairs.flatten)
      prepare_historical_batches!(pairs, live_records)
      normalize_live_records(live_records)
    end

    #: (untyped) -> bool
    def symbolic?(endpoint)
      BatchBoundaryResolver.symbolic?(endpoint)
    end

    # A boundary symbol that stayed unresolved means the root has no recorded
    # history. An absent history is an empty result rather than a failed
    # request, matching how the timeline APIs answer the same question.
    #: (Array[[untyped, untyped]], Hash[identity, RecordSnapshot]) -> comparison_results
    def results(resolved, live_snapshots)
      resolved.to_h do |from, to|
        identity = Support.immutable_copy(entry_identity(from, to))
        next [identity, Diff.new] if symbolic?(from) || symbolic?(to)

        [identity, compare(from, to, live_snapshots)]
      end
    end

    #: (untyped, untyped) -> identity
    def entry_identity(from, to)
      Endpoint.identity(symbolic?(from) ? to : from)
    end

    #: (untyped, untyped, Hash[identity, RecordSnapshot]) -> Diff
    def compare(from, to, live_snapshots)
      Engine.compare(snapshot(from, live_snapshots), snapshot(to, live_snapshots))
    end

    #: (untyped, Hash[identity, RecordSnapshot]) -> RecordSnapshot?
    def snapshot(endpoint, live_snapshots)
      return @historical_snapshotter.call(endpoint) if Endpoint.version?(endpoint)

      live_snapshots.fetch(Endpoint.identity(endpoint))
    end

    #: (Array[untyped]) -> Hash[identity, untyped]
    def load_live_records(endpoints)
      records = endpoints.reject { |endpoint| Endpoint.version?(endpoint) }.uniq do |record|
        Endpoint.identity(record)
      end
      @live_loader.call(records)
    end

    #: (Hash[identity, untyped]) -> Hash[identity, RecordSnapshot]
    def normalize_live_records(records)
      records.transform_values { |record| @live_normalizer.call(record) }
    end

    #: (Array[[untyped, untyped]], Hash[identity, untyped]) -> void
    def prepare_historical_batches!(pairs, live_records)
      loaded, unloaded = historical_versions(pairs).partition do |version|
        live_records.key?(Endpoint.identity(version))
      end
      loaded.group_by { |version| RecordedClass.for(version) }.each_value do |versions|
        records = versions.map { |version| live_records.fetch(Endpoint.identity(version)) }.uniq
        @history_preparer.call(records, versions)
      end
      prepare_version_roots!(unloaded)
    end

    # A root compared only between versions has no live endpoint, and its row
    # may be gone. Without prepared history, PT-AT finds a has_many's children
    # by the keys each version recorded after its change, so it misses a child
    # that later moved to another owner. Such roots are prepared from identity
    # alone, like deleted ones. Their history still reads the live rows it
    # needs: a record's current row is its state after its last version.
    #: (Array[untyped]) -> void
    def prepare_version_roots!(versions)
      versions.group_by { |version| RecordedClass.for(version) }.each do |model, group|
        ids = group.map(&:item_id).uniq(&:to_s)
        @version_history_preparer.call(ids.map { |id| historical_root(model, id) }, group)
      end
    end

    # The record supplies identity and model metadata only.
    #: (untyped, untyped) -> untyped
    def historical_root(model, id)
      record = model.new
      record[model.primary_key] = id
      record
    end

    #: (Array[[untyped, untyped]]) -> Array[untyped]
    def historical_versions(pairs)
      selected = pairs.flatten.select { |endpoint| Endpoint.version?(endpoint) }
      selected.uniq { |version| [version.class.name, version.id] }
    end

    #: () -> Array[[untyped, untyped]]
    def comparison_pairs
      unless @comparisons.is_a?(Array)
        raise ConfigurationError, 'comparisons: must be an array of from:/to: hashes'
      end

      @comparisons.map.with_index do |comparison, index|
        comparison_pair(comparison, index)
      end
    end

    #: (untyped, Integer) -> [untyped, untyped]
    def comparison_pair(comparison, index)
      valid_comparison!(comparison, index)
      [endpoint(comparison, :from), endpoint(comparison, :to)]
    end

    #: (untyped, Integer) -> void
    def valid_comparison!(comparison, index)
      if comparison.is_a?(Hash)
        keys = comparison.keys.map(&:to_s)
        return if keys.sort == %w[from to] && keys.length == 2
      end

      message = "comparisons[#{index}]: must contain exactly from: and to:"
      raise ConfigurationError, message
    end

    #: (Hash[untyped, untyped], Symbol) -> untyped
    def endpoint(comparison, name)
      comparison.key?(name) ? comparison.fetch(name) : comparison.fetch(name.to_s)
    end

    #: (Array[[untyped, untyped]]) -> void
    def ensure_unique_identities!(pairs)
      identities = pairs.map { |from, to| entry_identity(from, to) }
      return if identities.uniq.length == identities.length

      raise ConfigurationError, 'comparisons: root identities must be unique'
    end

    #: (Array[[untyped, untyped]]) -> void
    def prepare_endpoint_classes!(pairs)
      endpoint_requirements(pairs).each do |model_class, historical|
        @preparer.call(model_class, historical: historical)
      end
    end

    #: (Array[[untyped, untyped]]) -> Hash[untyped, bool]
    def endpoint_requirements(pairs)
      requirements = {} #: Hash[untyped, bool]
      pairs.flatten.each_with_object(requirements) do |endpoint, collected|
        historical = Endpoint.version?(endpoint)
        model_class = historical ? RecordedClass.for(endpoint) : endpoint.class
        collected[model_class] = collected.fetch(model_class, false) || historical
      end
    end
  end
end
