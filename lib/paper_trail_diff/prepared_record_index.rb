# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Immutable scalar state from a PaperTrail version or live-record fallback.
  class PreparedRecordState
    attr_reader :model_class #: untyped
    attr_reader :attributes #: Hash[untyped, untyped]

    #: (untyped) -> void
    def initialize(record)
      @model_class = record.class
      @attributes = Support.immutable_copy(record.attributes)
      freeze
    end

    #: (untyped, Hash[untyped, untyped]) -> PreparedRecordState
    def self.from_attributes(model_class, attributes)
      state = allocate
      state.send(:initialize_attributes, model_class, attributes)
      state
    end

    #: () -> untyped
    def instantiate
      @model_class.new(@attributes)
    end

    private

    #: (untyped, Hash[untyped, untyped]) -> void
    def initialize_attributes(model_class, attributes)
      @model_class = model_class
      @attributes = Support.immutable_copy(attributes)
      freeze
    end
  end

  # Extracts a version's scalar state without constructing a disposable AR object.
  class PreparedVersionStateLoader
    #: () -> void
    def initialize
      @serializers = {} #: Hash[untyped, untyped]
      @attribute_names = {} #: Hash[untyped, Array[String]]
    end

    #: (untyped) -> PreparedRecordState?
    def call(version)
      return unless version.object

      attributes = version.object_deserialized
      return unless attributes.is_a?(Hash)

      attributes = stringify_keys(attributes)
      model_class = reification_class(version, attributes)
      return unless direct_attributes?(model_class, attributes)

      object_attribute_serializer(model_class).deserialize(attributes)
      PreparedRecordState.from_attributes(model_class, attributes)
    rescue StandardError
      nil
    end

    private

    # @rbs @serializers: Hash[untyped, untyped]
    # @rbs @attribute_names: Hash[untyped, Array[String]]

    #: (Hash[untyped, untyped]) -> Hash[String, untyped]
    def stringify_keys(attributes)
      attributes.to_h { |name, value| [name.to_s, value] }
    end

    #: (untyped, Hash[String, untyped]) -> untyped
    def reification_class(version, attributes)
      model_class = Endpoint.model_class(version)
      inheritance_value = attributes[model_class.inheritance_column]
      return model_class if inheritance_value.nil? || inheritance_value.to_s.empty?

      model_class.sti_class_for(inheritance_value)
    end

    #: (untyped, Hash[String, untyped]) -> bool
    def direct_attributes?(model_class, attributes)
      encrypted = model_class.encrypted_attributes if model_class.respond_to?(:encrypted_attributes)
      return false if encrypted&.any?

      names = @attribute_names[model_class] ||= model_class.attribute_names
      (attributes.keys - names).empty?
    end

    #: (untyped) -> untyped
    def object_attribute_serializer(model_class)
      paper_trail = Object.const_get(:PaperTrail)
      serializers = paper_trail.const_get(:AttributeSerializers)
      serializer_class = serializers.const_get(:ObjectAttribute)
      @serializers[model_class] ||= serializer_class.new(model_class)
    end
  end

  # Versions and live fallback for one model identity.
  class PreparedRecordSeries
    attr_reader :versions #: Array[untyped]

    #: (versions: Array[untyped], live: PreparedRecordState?, ?state_loader: PreparedVersionStateLoader) -> void
    def initialize(versions:, live:, state_loader: PreparedVersionStateLoader.new)
      @versions = versions.sort_by { |version| Support.chronological_version_key(version) }.freeze
      @version_positions = @versions.each_with_index.to_h do |version, index|
        [version.id.to_s, index]
      end.freeze
      @live = live
      @state_loader = state_loader
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

    #: (untyped) -> [Hash[untyped, untyped], Hash[untyped, untyped]]?
    def transition(version)
      index = @version_positions[version.id.to_s]
      return unless index

      before = state_for(versions.fetch(index))
      after = state_after(index)
      return unless before && after && before.model_class == after.model_class

      [before.attributes, after.attributes]
    end

    private

    # @rbs @live: PreparedRecordState?
    # @rbs @state_loader: PreparedVersionStateLoader
    # @rbs @states: Hash[untyped, PreparedRecordState?]
    # @rbs @version_positions: Hash[String, Integer]

    #: (Integer) -> PreparedRecordState?
    def state_after(index)
      successor = versions[index + 1]
      successor ? state_for(successor) : @live
    end

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

      prepared = @state_loader.call(version)
      return @states[version.id] = prepared if prepared

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
      @state_loader = PreparedVersionStateLoader.new
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

    #: (untyped, untyped, untyped) -> [Hash[untyped, untyped], Hash[untyped, untyped]]?
    def transition(model_class, id, version)
      @series[identity(model_class, id)]&.transition(version)
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
    # @rbs @state_loader: PreparedVersionStateLoader
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
        live: record && PreparedRecordState.new(record),
        state_loader: @state_loader
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
