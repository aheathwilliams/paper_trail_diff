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
      @attributes = stored_attributes(record.class, record.attributes)
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
      @attributes = stored_attributes(model_class, attributes)
      freeze
    end

    # A live fallback and a version decoded from history must agree on what
    # the stored history could represent, or the gap between them reads as a
    # change.
    #: (untyped, Hash[untyped, untyped]) -> Hash[untyped, untyped]
    def stored_attributes(model_class, attributes)
      Support.immutable_copy(StoredValues.apply(model_class, attributes))
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

      model_class = reification_class(version, attributes.transform_keys(&:to_s))
      attributes = Support.decodable(attributes, model_class)
      return unless direct_attributes?(model_class, attributes)

      object_attribute_serializer(model_class).deserialize(attributes)
      PreparedRecordState.from_attributes(model_class, attributes)
    rescue StandardError
      nil
    end

    private

    # @rbs @serializers: Hash[untyped, untyped]
    # @rbs @attribute_names: Hash[untyped, Array[String]]

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

    # The live fallback is a state, or a current record whose state is read
    # the first time a read reaches past the last version. Most reads stop at
    # a version, and reading a row's state casts every column it has.
    #: (versions: Array[untyped], live: PreparedRecordState?, ?live_record: untyped, ?state_loader: PreparedVersionStateLoader) -> void
    def initialize(versions:, live:, live_record: nil, state_loader: PreparedVersionStateLoader.new)
      @versions = Support.chronological_sort(versions).freeze
      @times = @versions.map(&:created_at).freeze
      @version_positions = @versions.each_with_index.to_h do |version, index|
        [version.id.to_s, index]
      end.freeze
      @transaction_positions = build_transaction_positions
      @live = live
      @live_record = live_record
      @state_loader = state_loader
      @states = {} #: Hash[untyped, PreparedRecordState?]
    end

    # `ends` says where each transaction of the timeline being read takes
    # effect. A record then reads as it stood before every transaction that
    # ends at or after the boundary's own (see TransactionEnds); without it,
    # as it stood before the boundary's transaction.
    #: (untyped, ?TransactionEnds?) -> untyped
    def record_before(boundary, ends = nil)
      state_before(boundary, ends)&.instantiate
    end

    #: (untyped, ?TransactionEnds?) -> PreparedRecordState?
    def state_before(boundary, ends = nil)
      index = ends ? effective_index(boundary, ends) : boundary_index(boundary)
      return state_for(versions.fetch(index)) if index

      live
    end

    # A handled nil is known absence, not permission to query the current row.
    #: (untyped, ?direct: bool) -> [bool, untyped]
    def record_after(version, direct: false)
      index = @version_positions[version.id.to_s]
      return [false, nil] unless index

      state = state_after(index)
      [true, direct ? state : state&.instantiate]
    end

    #: () -> Array[untyped]
    def records
      states.map(&:instantiate)
    end

    #: () -> Array[PreparedRecordState]
    def states
      recorded = versions.filter_map { |version| state_for(version) }
      current = live
      current ? [*recorded, current] : recorded
    end

    # The classes the record had at any point, or either side of one version:
    # a create has no state before it and a destroy none after.
    #: (?untyped) -> Array[untyped]
    def model_classes(version = nil)
      return states.map(&:model_class) unless version

      states_across(version, version).map(&:model_class)
    end

    # The states before `first` and after `last`, where they exist.
    #: (untyped, untyped) -> Array[PreparedRecordState]
    def states_across(first, last)
      [state_for(first), state_after(@version_positions.fetch(last.id.to_s))].compact
    end

    # The states before the transaction of another record's version `first`
    # and after the transaction of its version `last`: what this record was
    # while that record's transaction began and once it had ended.
    #: (untyped, untyped) -> Array[PreparedRecordState]
    def states_around(first, last)
      [state_before(first), state_after_transaction(last)].compact
    end

    #: (untyped) -> [PreparedRecordState, PreparedRecordState]?
    def transition(version)
      index = @version_positions[version.id.to_s]
      return unless index

      before = state_for(versions.fetch(index))
      after = state_after(index)
      return unless before && after && before.model_class == after.model_class

      [before, after]
    end

    private

    # @rbs @times: Array[untyped]
    # @rbs @live: PreparedRecordState?
    # @rbs @live_record: untyped
    # @rbs @state_loader: PreparedVersionStateLoader
    # @rbs @states: Hash[untyped, PreparedRecordState?]
    # @rbs @version_positions: Hash[String, Integer]
    # @rbs @transaction_positions: Hash[untyped, Integer]
    # @rbs @effective: [TransactionEnds, Array[untyped]]?

    # The state before this record's first version past `boundary` and its
    # transaction, or the live one.
    #: (untyped) -> PreparedRecordState?
    def state_after_transaction(boundary)
      key = VersionBoundary.transaction_id(boundary)
      later = versions.find do |version|
        VersionBoundary.at_or_after?(version, boundary) &&
          (key.nil? || VersionBoundary.transaction_id(version) != key)
      end
      later ? state_for(later) : live
    end

    #: (Integer) -> PreparedRecordState?
    def state_after(index)
      successor = versions[index + 1]
      successor ? state_for(successor) : live
    end

    #: () -> PreparedRecordState?
    def live
      record = @live_record
      return @live unless record

      @live_record = nil
      @live = PreparedRecordState.new(record)
    end

    # A version is eligible when it is at or after the boundary, or shares the
    # boundary's transaction. The first is monotonic over the chronological
    # list and the other is indexed, so neither rescans a long history once
    # per boundary.
    #
    # "At or after" is decided by the version order rather than the timestamp
    # alone. A version written in the same instant as the boundary but before
    # it already took effect there; reading its pre-change state would put the
    # boundary on the wrong side of a change it follows. Each time is read
    # once, since every record is placed against every boundary.
    #: (untyped) -> Integer?
    def boundary_index(boundary)
      boundary_time = boundary.created_at
      chronological = (0...versions.length).bsearch do |index|
        VersionBoundary.at_or_after?(versions.fetch(index), boundary,
                                     time: @times.fetch(index), boundary_time: boundary_time)
      end
      [chronological, transaction_index(boundary)].compact.min
    end

    # The first version whose transaction ends at or after the boundary's.
    # One record's versions end in the order they
    # were saved, since a transaction holds a record it saved until it ends;
    # where history says otherwise, a version counts as ending no earlier
    # than those before it.
    #: (untyped, TransactionEnds) -> Integer?
    def effective_index(boundary, ends)
      target, target_time = ends.target(boundary)
      effective = effective_versions(ends)
      (0...effective.length).bsearch do |index|
        VersionBoundary.at_or_after?(effective.fetch(index), target, boundary_time: target_time)
      end
    end

    # Where each version takes effect: the last version of its transaction,
    # or of an earlier version's when that one ends later.
    #: (TransactionEnds) -> Array[untyped]
    def effective_versions(ends)
      held = @effective
      return held.last if held && held.first.equal?(ends)

      effective = placed(ends)
      @effective = [ends, effective]
      effective
    end

    #: (TransactionEnds) -> Array[untyped]
    def placed(ends)
      latest = nil
      versions.map do |version|
        last = ends.last(version)
        latest = last if latest.nil? || Support.compare_versions(last, latest).positive?
        latest
      end
    end

    #: (untyped) -> Integer?
    def transaction_index(boundary)
      transaction_id = VersionBoundary.transaction_id(boundary)
      return unless transaction_id

      @transaction_positions[transaction_id]
    end

    #: () -> Hash[untyped, Integer]
    def build_transaction_positions
      positions = {} #: Hash[untyped, Integer]
      @versions.each_with_index do |version, index|
        transaction_id = VersionBoundary.transaction_id(version)
        positions[transaction_id] ||= index if transaction_id
      end
      positions.freeze
    end

    #: (untyped) -> PreparedRecordState?
    def state_for(version)
      return @states[version.id] if @states.key?(version.id)
      return @states[version.id] = nil unless version.object

      prepared = @state_loader.call(version)
      return @states[version.id] = prepared if prepared

      record = Support.reify(
        version,
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
      @seeded_live_records = live_records.to_h { |row| [identity(row.class, row.id), row] }
      @state_loader = PreparedVersionStateLoader.new
      @series = {} #: Hash[Array[String], PreparedRecordSeries]
      @recorded_ends = RecordedTransactionEnds.new
      @direct_loader = DirectRecordStateLoader.new
      @direct_states = {} #: Hash[PreparedRecordState, PreparedRecordState?]
    end

    #: (untyped, Array[untyped]) -> void
    def load(model_class, ids)
      missing = missing_ids(model_class, ids)
      return if missing.empty?

      versions = versions_for(model_class, missing).group_by { |version| version.item_id.to_s }
      live = available_live_records(model_class, missing).to_h { |record| [record.id.to_s, record] }
      missing.each { |id| add_series(model_class, id, versions, live) }
    end

    # When the history was read from.
    #: () -> untyped
    attr_reader :start_time

    # When it was read to, if it ends.
    #: () -> untyped
    attr_reader :end_time

    # Where the transactions of these versions take effect, as their version
    # tables record it (see RecordedTransactionEnds).
    #: (Array[untyped]) -> TransactionEnds
    def transaction_ends(versions)
      TransactionEnds.new(versions, @recorded_ends.call(versions) { self.versions })
    end

    #: (untyped, untyped, untyped) -> untyped
    def record_before(model_class, id, boundary)
      @series.fetch(identity(model_class, id)).record_before(boundary, @ends)
    end

    # Reads for a root's timeline, each record as it stood before every
    # transaction that had not ended at the boundary it is read at (see
    # TransactionEnds).
    #: (TransactionEnds) { () -> void } -> void
    def reading(ends)
      previous = @ends
      @ends = ends
      yield
    ensure
      @ends = previous
    end

    # What a read is made with now, if a timeline is being read.
    #: () -> TransactionEnds?
    def reading_ends = @ends

    #: (untyped, untyped, untyped) -> [bool, PreparedRecordState?]
    def snapshot_state_before(model_class, id, boundary)
      series = @series[identity(model_class, id)]
      return [false, nil] unless series

      state = series.state_before(boundary, @ends)
      return [true, nil] unless state

      prepared = direct_state(state)
      [!prepared.nil?, prepared]
    end

    # Typed as a reified record's attributes are. A JSON or JSONB `object`
    # column stores times and dates as strings, which PaperTrail does not cast
    # back, and the transition is carried into snapshots built from records.
    #: (untyped, untyped, untyped) -> [Hash[untyped, untyped], Hash[untyped, untyped]]?
    def transition(model_class, id, version)
      states = @series[identity(model_class, id)]&.transition(version)
      return unless states

      [typed_attributes(states.fetch(0)), typed_attributes(states.fetch(1))]
    end

    #: (untyped, untyped, untyped, ?direct: bool) -> [bool, untyped]
    def record_after(model_class, id, version, direct: false)
      handled, state = @series[identity(model_class, id)]&.record_after(version, direct: direct)
      return [false, nil] unless handled
      return [true, state] unless direct && state

      prepared = direct_state(state)
      [!prepared.nil?, prepared]
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def records_for(model_class, ids)
      ids.flat_map { |id| @series.fetch(identity(model_class, id)).records }
    end

    #: (untyped, Array[untyped], String) -> Array[untyped]
    def attribute_values_for(model_class, ids, name)
      plain_reader = generated_reader?(model_class, name)
      ids.flat_map do |id|
        @series.fetch(identity(model_class, id)).states.map do |state|
          direct = direct_state(state) if plain_reader
          direct ? direct.attributes[name] : state.instantiate.public_send(name)
        end
      end
    end

    #: (untyped, untyped) -> Array[untyped]
    def versions_for_id(model_class, id)
      @series.fetch(identity(model_class, id)).versions
    end

    #: () -> Array[untyped]
    def versions
      @series.each_value.flat_map(&:versions)
    end

    #: (untyped, untyped, ?untyped) -> Array[untyped]
    def model_classes(model_class, id, version = nil)
      @series.fetch(identity(model_class, id)).model_classes(version)
    end

    # The attributes before `first` and after `last`, where they exist, typed
    # as a reified record's are.
    #: (untyped, untyped, untyped, untyped) -> Array[Hash[untyped, untyped]]
    def typed_states_across(model_class, id, first, last)
      @series.fetch(identity(model_class, id)).states_across(first, last)
             .map { |state| typed_attributes(state) }
    end

    # A record's attributes around another record's transaction (see
    # PreparedRecordSeries#states_around), typed as typed_states_across's.
    #: (untyped, untyped, untyped, untyped) -> Array[Hash[untyped, untyped]]
    def typed_states_around(model_class, id, first, last)
      @series.fetch(identity(model_class, id)).states_around(first, last)
             .map { |state| typed_attributes(state) }
    end

    #: (untyped, untyped) -> bool
    def loaded?(model_class, id)
      @series.key?(identity(model_class, id))
    end

    private

    # A model whose records need their own initialization is cast by
    # instantiating it, as reify does.
    #: (PreparedRecordState) -> Hash[untyped, untyped]
    def typed_attributes(state)
      typed = direct_state(state)
      return typed.attributes if typed

      PreparedRecordState.new(state.instantiate).attributes
    end

    # A state completed as a record of its class would hold it, or nil where
    # only instantiating can tell; each state is completed once.
    #: (PreparedRecordState) -> PreparedRecordState?
    def direct_state(state)
      @direct_states.fetch(state) { @direct_states[state] = @direct_loader.complete(state) }
    end

    #: (untyped, String) -> bool
    def generated_reader?(model, name)
      model.define_attribute_methods
      model.instance_method(name).owner.name.to_s.end_with?('GeneratedAttributeMethods')
    end

    # @rbs @start_time: untyped
    # @rbs @end_time: untyped
    # @rbs @seeded_live_records: Hash[Array[String], untyped]
    # @rbs @state_loader: PreparedVersionStateLoader
    # @rbs @series: Hash[Array[String], PreparedRecordSeries]
    # @rbs @direct_loader: DirectRecordStateLoader
    # @rbs @direct_states: Hash[PreparedRecordState, PreparedRecordState?]
    # @rbs @ends: TransactionEnds?
    # @rbs @recorded_ends: RecordedTransactionEnds

    # Callers bound the range with either a version or a bare timestamp.
    #: (untyped) -> untyped
    def boundary_time(value)
      value.respond_to?(:created_at) ? value.created_at : value
    end

    #: (untyped, untyped) -> Array[String]
    def identity(model_class, id)
      Support.record_identity(model_class, id)
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def missing_ids(model_class, ids)
      ids.compact.uniq.reject { |id| @series.key?(identity(model_class, id)) }
    end

    #: (untyped, untyped, Hash[String, Array[untyped]], Hash[String, untyped]) -> void
    def add_series(model_class, id, versions, live)
      record = live[id.to_s]
      @series[identity(model_class, id)] = PreparedRecordSeries.new(
        versions: versions.fetch(id.to_s, []), live: nil, live_record: record,
        state_loader: @state_loader
      )
    end

    # A PaperTrail version is a pre-change snapshot, so the state at the last
    # selected boundary can only live in the next version after it. One
    # trailing version per identity is retained, rather than every version
    # recorded between the requested range and the present. Each record's
    # versions are read in one statement, which takes 500 records.
    #: (untyped, Array[untyped]) -> Array[untyped]
    def versions_for(model_class, ids)
      ids.each_slice(Support::IDS_PER_STATEMENT).flat_map do |slice|
        scope = VersionQuery.for_items(model_class, slice).where(created_at: @start_time..)
        scope = scope.where(window_condition(model_class.paper_trail.version_class)) if @end_time
        scope.order(:id).to_a
      end
    end

    # In range, or the earliest version after it, resolved in the same query
    # rather than with a window function or one query per identity.
    #: (untyped) -> untyped
    def window_condition(version_class)
      table = version_class.arel_table
      first_after = VersionQuery.no_earlier_version(table) do |earlier|
        earlier[:created_at].gt(@end_time)
      end
      table[:created_at].lteq(@end_time).or(first_after)
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

      ids.each_slice(Support::IDS_PER_STATEMENT).flat_map do |slice|
        model_class.base_class.unscoped.where(primary_key => slice).to_a
      end
    end
  end

  # Finds where the earliest transaction open at a window's start began.
  #
  # A transaction open at the start saved a version before it and another
  # from it onward. Either can be of a record the history does not hold, such
  # as one the transaction moved out of the tree before the window and never
  # saved again, so every such transaction of the tree's version tables is
  # read, not only those of the versions held: one statement per table.
  #
  # Another version table can number a transaction as this one numbered an
  # earlier one, so versions an anchor separates from the start are not read
  # as one transaction's (see TransactionAnchors).
  #
  # Nothing is read past a window's end. A transaction that crosses it is
  # placed by its last version, which its version table names (see
  # RecordedTransactionEnds), so after the window.
  class CrossingTransactions
    #: (Enumerable[untyped], untyped) -> void
    def initialize(version_classes, start)
      @version_classes = version_classes
      @start = start
    end

    # Where the transactions open at `start` began, in these version tables;
    # nil when none is open, or without a start.
    #: (Enumerable[untyped], untyped) -> untyped
    def self.reach(version_classes, start)
      new(version_classes, start).call if start
    end

    # The same, in the version tables of the models of these names that
    # PaperTrail tracks.
    #: (Array[String], untyped) -> untyped
    def self.open_among(types, start)
      models = types.map { |type| Support.constant(type) }
                    .select { |model| Support.versioned?(model) }
      reach(models.map { |model| model.paper_trail.version_class }.uniq, start)
    end

    # The same, in the version tables of a root model and of the records on
    # its requested paths. A polymorphic belongs_to may reach a record of any
    # class, so with one every version table is read.
    #: (untyped, AssociationTraversal, untyped) -> untyped
    def self.open_around(model, traversal, start)
      return reach(every_version_class, start) if traversal.polymorphic_paths?(model)

      open_among([model.name, *traversal.path_types(model)], start)
    end

    # One version class for each version table the application defines.
    #: () -> Array[untyped]
    def self.every_version_class
      concern = Support.constant('PaperTrail::VersionConcern')
      Support.constant('ActiveRecord::Base').descendants.select do |candidate|
        candidate.include?(concern) && !candidate.abstract_class? && candidate.table_exists?
      end.uniq(&:table_name)
    end
    private_class_method :every_version_class

    # The versions of this table saved before `start` by the transactions
    # open at it.
    #: (untyped, untyped) -> untyped
    def self.saved_before(version_class, start)
      saved = version_class.where(version_class.arel_table[:created_at].lt(start))
      TransactionAnchors.scope(saved, version_class, start)
                        .where(transaction_id: later(version_class, start).select(:transaction_id))
    end

    # The versions saved from the start onward, of the transactions no anchor
    # separates from it. A transaction's versions can be dated out of the
    # order they were saved in, as when a callback saves other records before
    # its own version, dated as its save began, so each is judged by its date.
    #: (untyped, untyped) -> untyped
    def self.later(version_class, start)
      table = version_class.arel_table
      saved = version_class.where(table[:created_at].gteq(start)).where.not(transaction_id: nil)
      TransactionAnchors.scope(saved, version_class, start)
    end
    private_class_method :later

    #: () -> untyped
    def call
      @version_classes.filter_map { |version_class| open_at_start(version_class) }.min
    end

    private

    # @rbs @version_classes: Enumerable[untyped]
    # @rbs @start: untyped

    # When the earliest transaction open at the start began in this table.
    #: (untyped) -> untyped
    def open_at_start(version_class)
      return unless version_class.column_names.include?('transaction_id')

      self.class.saved_before(version_class, @start).minimum(:created_at)
    end
  end
end
