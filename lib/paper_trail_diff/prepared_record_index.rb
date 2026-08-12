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

    # Mirrors PaperTrail's reifier, which writes attributes directly. Mass
    # assignment would route reconstructed state through application-defined
    # attribute writers and reify a different record than the version stored.
    #: () -> untyped
    def instantiate
      record = @model_class.new
      @attributes.each { |name, value| record[name] = value }
      record
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
      @versions = Support.chronological_sort(versions).freeze
      @version_positions = @versions.each_with_index.to_h do |version, index|
        [version.id.to_s, index]
      end.freeze
      @transaction_positions = build_transaction_positions
      @live = live
      @state_loader = state_loader
      @states = {} #: Hash[untyped, PreparedRecordState?]
    end

    #: (untyped) -> untyped
    def record_before(boundary)
      index = boundary_index(boundary)
      return state_for(versions.fetch(index))&.instantiate if index

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
    # @rbs @transaction_positions: Hash[untyped, Integer]

    #: (Integer) -> PreparedRecordState?
    def state_after(index)
      successor = versions[index + 1]
      successor ? state_for(successor) : @live
    end

    # A version is eligible when it is at or after the boundary, or shares the
    # boundary's transaction. The first is monotonic over the chronological
    # list and the second is indexed, so neither rescans a long history once
    # per boundary.
    #: (untyped) -> Integer?
    def boundary_index(boundary)
      created_at = boundary.created_at
      chronological = versions.bsearch_index do |candidate|
        candidate.created_at >= created_at
      end
      transactional = transaction_index(boundary)
      return chronological unless transactional
      return transactional unless chronological

      [chronological, transactional].min
    end

    #: (untyped) -> Integer?
    def transaction_index(boundary)
      transaction_id = boundary.transaction_id if boundary.respond_to?(:transaction_id)
      return unless transaction_id

      @transaction_positions[transaction_id]
    end

    #: () -> Hash[untyped, Integer]
    def build_transaction_positions
      positions = {} #: Hash[untyped, Integer]
      @versions.each_with_index do |version, index|
        next unless version.respond_to?(:transaction_id)

        transaction_id = version.transaction_id
        positions[transaction_id] ||= index if transaction_id
      end
      positions.freeze
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
    #: (untyped, ?end_at: untyped, ?live_records: Array[untyped]) -> void
    def initialize(start_at, end_at: nil, live_records: [])
      @start_time = boundary_time(start_at)
      @end_time = boundary_time(end_at)
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
    # @rbs @end_time: untyped
    # @rbs @seeded_live_records: Hash[Array[String], untyped]
    # @rbs @state_loader: PreparedVersionStateLoader
    # @rbs @series: Hash[Array[String], PreparedRecordSeries]

    # Callers bound the range with either a version or a bare timestamp.
    #: (untyped) -> untyped
    def boundary_time(value)
      value.respond_to?(:created_at) ? value.created_at : value
    end

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

    # A PaperTrail version is a pre-change snapshot, so the state at the last
    # selected boundary can only live in the next version after it. One
    # trailing version per identity is retained, rather than every version
    # recorded between the requested range and the present.
    #: (untyped, Array[untyped]) -> Array[untyped]
    def versions_for(model_class, ids)
      version_class = model_class.paper_trail.version_class
      scope = version_class.where(
        item_type: model_class.base_class.name,
        item_id: ids
      ).where(created_at: @start_time..)
      scope = scope.where(window_condition(version_class)) if @end_time
      scope.order(:id).to_a
    end

    # In range, or the earliest version after it, resolved in the same query
    # rather than with a window function or one query per identity.
    #: (untyped) -> untyped
    def window_condition(version_class)
      table = version_class.arel_table
      table[:created_at].lteq(@end_time).or(first_after_range(table))
    end

    #: (untyped) -> untyped
    def first_after_range(table)
      arel = Object.const_get(:Arel) #: untyped
      later = table.alias('paper_trail_diff_later_versions')
      arel.const_get(:SelectManager).new
          .from(later)
          .project(arel.sql('1'))
          .where(preceding_trailing_version(table, later))
          .exists
          .not
    end

    #: (untyped, untyped) -> untyped
    def preceding_trailing_version(table, later)
      later[:item_type].eq(table[:item_type])
                       .and(later[:item_id].eq(table[:item_id]))
                       .and(later[:created_at].gt(@end_time))
                       .and(later[:created_at].lt(table[:created_at]))
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
