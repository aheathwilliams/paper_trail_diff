# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Immutable scalar state from a PaperTrail version or live-record fallback.
  class PreparedRecordState
    #: (untyped) -> void
    def initialize(record)
      @model_class = record.class
      @attributes = Support.immutable_copy(record.attributes)
      freeze
    end

    #: () -> untyped
    def instantiate
      @model_class.new(@attributes)
    end

    # @rbs @model_class: untyped
    # @rbs @attributes: Hash[untyped, untyped]
  end

  # Versions and live fallback for one model identity.
  class PreparedRecordSeries
    attr_reader :versions #: Array[untyped]

    #: (versions: Array[untyped], live: PreparedRecordState?) -> void
    def initialize(versions:, live:)
      @versions = versions.freeze
      @live = live
      @states = {} #: Hash[untyped, PreparedRecordState?]
    end

    #: (untyped) -> untyped
    def record_before(boundary)
      version = versions.find { |candidate| eligible?(candidate, boundary) }
      return state_for(version)&.instantiate if version

      @live&.instantiate
    end

    #: () -> Array[untyped]
    def records
      version_records = versions.filter_map { |version| state_for(version)&.instantiate }
      live = @live
      live ? [*version_records, live.instantiate] : version_records
    end

    private

    # @rbs @live: PreparedRecordState?
    # @rbs @states: Hash[untyped, PreparedRecordState?]

    #: (untyped, untyped) -> bool
    def eligible?(version, boundary)
      version.created_at >= boundary.created_at || same_transaction?(version, boundary)
    end

    #: (untyped, untyped) -> bool
    def same_transaction?(version, boundary)
      transaction_id = boundary.transaction_id if boundary.respond_to?(:transaction_id)
      transaction_id && version.respond_to?(:transaction_id) &&
        version.transaction_id == transaction_id
    end

    #: (untyped) -> PreparedRecordState?
    def state_for(version)
      return @states[version.id] if @states.key?(version.id)

      record = version.reify(
        dup: true,
        has_many: false,
        has_one: false,
        belongs_to: false,
        has_and_belongs_to_many: false
      )
      @states[version.id] = record && PreparedRecordState.new(record)
    end
  end

  # Request-scoped scalar history loaded once per model identity.
  class PreparedRecordIndex
    #: (untyped, ?live_records: Array[untyped]) -> void
    def initialize(start_at, live_records: [])
      @start_time = start_at
      @seeded_live_records = live_records.to_h do |record|
        [identity(record.class, record.id), record]
      end
      @series = {} #: Hash[Array[String], PreparedRecordSeries]
    end

    #: (untyped, Array[untyped]) -> void
    def load(model_class, ids)
      missing = missing_ids(model_class, ids)
      return if missing.empty?

      versions = versions_for(model_class, missing).group_by { |version| version.item_id.to_s }
      live = available_live_records(model_class, missing).to_h do |record|
        [record.id.to_s, record]
      end
      missing.each { |id| add_series(model_class, id, versions, live) }
    end

    #: (untyped, untyped, untyped) -> untyped
    def record_before(model_class, id, boundary)
      @series.fetch(identity(model_class, id)).record_before(boundary)
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def records_for(model_class, ids)
      ids.flat_map { |id| @series.fetch(identity(model_class, id)).records }
    end

    #: (untyped, untyped) -> bool
    def loaded?(model_class, id)
      @series.key?(identity(model_class, id))
    end

    private

    # @rbs @start_time: untyped
    # @rbs @seeded_live_records: Hash[Array[String], untyped]
    # @rbs @series: Hash[Array[String], PreparedRecordSeries]

    #: (untyped, untyped) -> Array[String]
    def identity(model_class, id)
      [model_class.base_class.name.to_s, id.to_s]
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def missing_ids(model_class, ids)
      ids.compact.uniq.reject { |id| @series.key?(identity(model_class, id)) }
    end

    #: (untyped, untyped, Hash[String, Array[untyped]], Hash[String, untyped]) -> void
    def add_series(model_class, id, versions, live)
      record = live[id.to_s]
      @series[identity(model_class, id)] = PreparedRecordSeries.new(
        versions: versions.fetch(id.to_s, []),
        live: record && PreparedRecordState.new(record)
      )
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def versions_for(model_class, ids)
      model_class.paper_trail.version_class.where(
        item_type: model_class.base_class.name,
        item_id: ids
      ).where('created_at >= ?', @start_time).order(:id).to_a
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def available_live_records(model_class, ids)
      seeded = ids.filter_map { |id| @seeded_live_records[identity(model_class, id)] }
      missing = ids.reject { |id| @seeded_live_records.key?(identity(model_class, id)) }
      seeded.concat(live_records_for(model_class, missing))
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def live_records_for(model_class, ids)
      return [] if ids.empty?

      primary_key = model_class.primary_key
      return [] if primary_key.is_a?(Array)

      model_class.base_class.unscoped.where(primary_key => ids).to_a
    end
  end
end
