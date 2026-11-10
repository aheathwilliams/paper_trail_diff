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

      attributes = Support.decodable(attributes)
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

    # A record created in the boundary's own transaction has no state before
    # it, yet a HABTM checkpoint saved later in that transaction records it as
    # a member. Such a member is read as it was created, at a boundary after
    # its creation; before it, the record did not exist yet.
    #: (untyped) -> untyped
    def record_created_in(boundary)
      index = transaction_index(boundary)
      return unless index

      version = versions.fetch(index)
      return unless version.event == 'create' && !VersionBoundary.at_or_after?(version, boundary)

      state_after(index)&.instantiate
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
    # One record's versions end in the order they were saved, since a
    # transaction holds a record it saved until it ends; where history says
    # otherwise, a version counts as ending no earlier than those before it.
    #: (untyped, TransactionEnds) -> Integer?
    def effective_index(boundary, ends)
      target = VersionBoundary.version_record?(boundary) ? ends.last(boundary) : boundary
      target_time = target.created_at
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

      latest = nil
      effective = versions.map do |version|
        last = ends.last(version)
        latest = last if latest.nil? || Support.compare_versions(last, latest).positive?
        latest
      end
      @effective = [ends, effective]
      effective
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
      @version_classes = Set.new #: Set[untyped]
      @recorded_ends = RecordedTransactionEnds.new
      @direct_loader = DirectRecordStateLoader.new
      @direct_states = {} #: Hash[PreparedRecordState, PreparedRecordState?]
    end

    #: (untyped, Array[untyped]) -> void
    def load(model_class, ids)
      @version_classes << model_class.paper_trail.version_class
      missing = missing_ids(model_class, ids)
      return if missing.empty?

      versions = versions_for(model_class, missing).group_by { |version| version.item_id.to_s }
      live = available_live_records(model_class, missing).to_h { |record| [record.id.to_s, record] }
      missing.each { |id| add_series(model_class, id, versions, live) }
    end

    #: (untyped, Array[untyped], Array[untyped]) -> void
    def seed(model_class, ids, versions)
      @version_classes << model_class.paper_trail.version_class
      grouped = versions.group_by { |version| version.item_id.to_s }
      live = available_live_records(model_class, ids).to_h { |record| [record.id.to_s, record] }
      ids.each { |id| add_series(model_class, id, grouped, live) }
    end

    # How far the transactions of the versions held in the range reach
    # outside it: where the earliest of those that began before the start
    # began, and where the latest of those that went on after the end saved
    # its last version. Either is nil when none did; see PreparedHistoryLoader.
    #: () -> [untyped, untyped]
    def reach = CrossingTransactions.reach(@series, @version_classes, @start_time, @end_time)

    # When the history was read from.
    #: () -> untyped
    attr_reader :start_time

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

    #: (untyped, untyped, untyped) -> untyped
    def record_created_in(model_class, id, boundary)
      @series.fetch(identity(model_class, id)).record_created_in(boundary)
    end

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
    # @rbs @version_classes: Set[untyped]
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

  # Finds how far the transactions around a window reach outside it: where
  # the earliest of those open at its start began, and where the latest of
  # those that cross either edge saved its last version.
  #
  # A transaction open at the start saved a version before it and another
  # from it onward. Either can be of a record the history does not hold, such
  # as one the transaction moved out of the tree before the window and never
  # saved again, so every such transaction of the tree's version tables is
  # read, not only those of the versions held: one statement per table when
  # none is open, which is the usual case, and one more per 500 that are. A
  # transaction's first version in a table cannot follow another of its own
  # there, so only the others are looked up.
  #
  # A transaction across the end saved a version held up to it and another
  # after it; one statement per 500 of them.
  #
  # Another version table can number a transaction as this one numbered an
  # earlier one, so versions an anchor separates from the edge are not read
  # as one transaction's (see TransactionAnchors).
  class CrossingTransactions
    #: (Hash[Array[String], PreparedRecordSeries], Array[untyped], untyped, untyped) -> void
    def initialize(series, version_classes, start, finish)
      @series = series
      @version_classes = version_classes
      @start = start
      @finish = finish
    end

    # The reach of a history read from `start`; none without one.
    #: (Hash[Array[String], PreparedRecordSeries], Enumerable[untyped], untyped, untyped) -> [untyped, untyped]
    def self.reach(series, version_classes, start, finish)
      start ? new(series, version_classes.to_a, start, finish).call : [nil, nil]
    end

    # How far the transactions open at `start` reach, in the version tables
    # of the models of these names that PaperTrail tracks; nil when none is
    # open, or without a start.
    #: (Array[String], untyped, untyped) -> [untyped, untyped]?
    def self.open_among(types, start, finish)
      models = types.map { |type| Support.constant(type) }
                    .select { |model| Support.versioned?(model) }
      found = reach({}, models.map { |model| model.paper_trail.version_class }.uniq, start, finish)
      found unless found.compact.empty?
    end

    # When the earliest transaction open at the start began, and when the
    # latest across an edge saved its last version; nil where none crossed.
    #: () -> [untyped, untyped]
    def call
      open = @version_classes.map { |version_class| open_at_start(version_class) }
      [open.filter_map(&:first).min, [*open.filter_map(&:last), *across_end].select do |at|
        past?(at)
      end.max]
    end

    private

    # @rbs @series: Hash[Array[String], PreparedRecordSeries]
    # @rbs @version_classes: Array[untyped]
    # @rbs @start: untyped
    # @rbs @finish: untyped

    #: (untyped) -> bool
    def past?(time)
      finish = @finish
      !finish.nil? && time > finish
    end

    # When the transactions open at the start began in this table, and when
    # the latest of them saved its last version there.
    #: (untyped) -> [untyped, untyped]
    def open_at_start(version_class)
      return [nil, nil] unless version_class.column_names.include?('transaction_id')

      edge = TransactionCut::Edge.start_at(@start)
      began = earlier(version_class, edge).group(:transaction_id).minimum(:created_at)
      return [nil, nil] if began.empty?

      ended = began.keys.each_slice(Support::IDS_PER_STATEMENT).filter_map do |numbers|
        later(version_class, edge).where(transaction_id: numbers).maximum(:created_at)
      end
      [began.values.min, ended.max]
    end

    # The versions saved before the start by a transaction that saved one
    # from it onward.
    #: (untyped, TransactionCut::Edge) -> untyped
    def earlier(version_class, edge)
      saved = version_class.where(version_class.arel_table[:created_at].lt(@start))
      TransactionAnchors.scope(saved, version_class, edge)
                        .where(transaction_id: later(version_class, edge).select(:transaction_id))
    end

    # The versions saved from the start onward that were not the first of
    # their transaction, of the transactions no anchor separates from it.
    #: (untyped, TransactionCut::Edge) -> untyped
    def later(version_class, edge)
      table = version_class.arel_table
      saved = version_class.where(table[:created_at].gteq(@start)).where.not(transaction_id: nil)
      if own_numbers?(version_class)
        saved = saved.where(table[version_class.primary_key].not_eq(table[:transaction_id]))
      end
      TransactionAnchors.scope(saved, version_class, edge)
    end

    # Whether the table's ids can number its transactions, as they do unless
    # the two columns differ in type.
    #: (untyped) -> bool
    def own_numbers?(version_class)
      key = version_class.primary_key
      number = version_class.type_for_attribute('transaction_id').type
      key.is_a?(String) && version_class.type_for_attribute(key).type == number
    end

    # When each transaction of the versions held up to the end saved its last
    # version after it.
    #: () -> Array[untyped]
    def across_end
      finish = @finish
      return [] unless finish

      held = versions.select { |version| version.created_at.between?(@start, finish) }
      transactions(held).flat_map do |version_class, by_number|
        by_number.each_slice(Support::IDS_PER_STATEMENT).flat_map do |slice|
          last_after(version_class, slice.to_h, finish)
        end
      end
    end

    # When each of these transactions saved its last version after the end,
    # by the version held of each.
    #: (untyped, Hash[untyped, untyped], untyped) -> Array[untyped]
    def last_after(version_class, held, finish)
      saved = version_class.where(transaction_id: held.keys)
                           .where(version_class.arel_table[:created_at].gt(finish))
      edge = TransactionCut::Edge.new(finish, true)
      TransactionAnchors.continued(saved, version_class, edge, held.values.map(&:id))
                        .group(:transaction_id).maximum(:created_at).values
    end

    # The transactions of the versions, by version class, since each version
    # table is read for its own, with one version held of each.
    #: (Array[untyped]) -> Hash[untyped, Hash[untyped, untyped]]
    def transactions(held)
      found = {} #: Hash[untyped, Hash[untyped, untyped]]
      held.each_with_object(found) do |version, by_class|
        (by_class[version.class] ||= {})[VersionBoundary.transaction_id(version)] ||= version
      end
    end

    # The versions held that a transaction saved.
    #: () -> Array[untyped]
    def versions
      @versions ||= @series.each_value.flat_map do |series|
        series.versions.select { |version| VersionBoundary.transaction_id(version) }
      end
    end

    # @rbs @versions: Array[untyped]?
  end
end
