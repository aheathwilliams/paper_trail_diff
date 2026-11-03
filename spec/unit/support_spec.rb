# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::Support do
  let(:noon) { Time.utc(2032, 1, 1, 12) }

  # Versions of two tables, and of one whose ids do not count up.
  let(:version) { Struct.new(:created_at, :id) { def self.table_name = 'versions' } }
  let(:other_version) { Struct.new(:created_at, :id) { def self.table_name = 'other_versions' } }

  describe '.per_model' do
    it 'answers once for each Active Record class, and every time for anything else' do
      answers = {}
      asked = []
      ask = lambda do |value|
        described_class.per_model(answers, value) { |seen| (asked << seen).length }
      end
      first = FilterArticle.new
      second = FilterArticle.new
      plain = Object.new

      expect([first, second, plain, plain].map(&ask)).to eq([1, 1, 2, 3])
      expect(asked).to eq([first, plain, plain])
      expect(answers).to eq(FilterArticle => 1)
    end
  end

  describe '.decodable' do
    # The wrapper delegates ==, so only its class tells it from the time.
    it 'keys stored values by name, unwrapping each time of day, alone or in a pair' do
      wrapped = ActiveRecord::Type::Time::Value.new(noon)
      # As YAML loads a zone-aware time stored as a TimeWithZone's fields.
      fields = ActiveRecord::Type::Time::Value.allocate
      fields.instance_variable_set(:@time, noon)

      decodable = described_class.decodable(rings_at: wrapped, 'changed' => [nil, wrapped],
                                            'title' => 'Draft', 'labels' => [1, 2],
                                            'zoned' => fields)

      expect(decodable).to eq('rings_at' => noon, 'changed' => [nil, noon], 'title' => 'Draft',
                              'labels' => [1, 2], 'zoned' => noon)
      expect([decodable.fetch('rings_at'), decodable.fetch('changed').last])
        .to all(be_an_instance_of(Time))
    end
  end

  describe '.with_recorded_times and .reify' do
    # A record as PaperTrail's reify leaves it: linked to its version, with
    # the time of day nil.
    let(:model) do
      Class.new do
        attr_reader :version, :assigned
        attr_accessor :alarm

        def self.version_association_name = :version

        def initialize(version)
          @version = version
          @assigned = {}
        end

        def has_attribute?(name) = name == 'rings_at'

        def []=(name, value)
          @assigned[name] = value
        end
      end
    end

    let(:wrapped) { ActiveRecord::Type::Time::Value.new(noon) }

    def stored(object, attributes = {})
      double(object: object, object_deserialized: attributes)
    end

    it 'assigns each time of day its version recorded, as PaperTrail assigns attributes' do
      fields = ActiveRecord::Type::Time::Value.allocate
      fields.instance_variable_set(:@time, noon)
      version = stored("rings_at: !ruby/object:#{described_class::TIME_VALUE}",
                       'title' => 'Draft', 'rings_at' => wrapped, 'alarm' => fields,
                       'gone' => wrapped)
      record = model.new(version)

      expect(described_class.with_recorded_times(record)).to equal(record)
      expect(record.assigned).to eq(rings_at: noon)
      expect(record.assigned.fetch(:rings_at)).to be_an_instance_of(Time)
      expect(record.alarm).to be_an_instance_of(Time)
      expect(record.alarm).to eq(noon)
    end

    it 'decodes nothing again when the stored text holds no time of day, or is not text' do
      ['title: Draft', { 'rings_at' => '12:00' }, nil].each do |object|
        version = stored(object)
        record = model.new(version)

        expect(described_class.with_recorded_times(record)).to equal(record)
        expect(version).not_to have_received(:object_deserialized)
        expect(record.assigned).to be_empty
      end
    end

    it 'returns a record PaperTrail did not rebuild, or none, as it is' do
      record = model.new(nil)
      plain = Object.new

      expect(described_class.with_recorded_times(record)).to equal(record)
      expect(described_class.with_recorded_times(plain)).to equal(plain)
      expect(described_class.with_recorded_times(nil)).to be_nil
    end

    it "is PaperTrail's reify with the options given, and the version's times" do
      version = stored("rings_at: !ruby/object:#{described_class::TIME_VALUE}",
                       'rings_at' => wrapped)
      record = model.new(version)
      allow(version).to receive(:reify).with(dup: true, has_many: false).and_return(record)

      expect(described_class.reify(version, dup: true, has_many: false)).to equal(record)
      expect(record.assigned).to eq(rings_at: noon)
    end
  end

  describe '.immutable_copy' do
    it 'copies hashes and arrays all the way down, keys too, and freezes the copy' do
      key = [+'key']
      value = { key => [+'a', { +'deep' => +'b' }] }

      copy = described_class.immutable_copy(value)
      inner = copy.fetch(key).last

      expect(copy).to eq(value)
      parts = [copy, copy.keys.first, copy.fetch(key), inner, inner.keys.first, inner.values.first]

      expect(parts).to all(be_frozen)
      expect([value, key, key.first, value.fetch(key).first])
        .to all(satisfy { |part| !part.frozen? })
    end

    it 'keeps a frozen value, and gives a frozen copy of any other' do
      frozen = 'same'
      mutable = +'text'

      copy = described_class.immutable_copy(mutable)

      expect(described_class.immutable_copy(frozen)).to equal(frozen)
      expect([copy, copy.frozen?, copy.equal?(mutable), mutable.frozen?])
        .to eq(['text', true, false, false])
    end

    it 'keeps a value it cannot copy' do
      undupable = Class.new { def initialize_copy(*) = raise(TypeError, 'no copies') }.new

      expect(described_class.immutable_copy(undupable)).to equal(undupable)
      expect(undupable).not_to be_frozen
    end
  end

  describe '.serialize' do
    it 'gives plain copies all the way down, and a result object as its hash' do
      change = PaperTrailDiff::ValueChange.new(from: 1, to: 2)
      plain = stub_const('PlainValue', Struct.new(:a)).new(1)
      unnamed = Class.new { def to_h = { a: 1 } }.new
      error = PaperTrailDiff::Error.new('kept')
      value = { 'list' => [change, { 'deep' => change }].freeze,
                'other' => [plain, unnamed, error] }

      serialized = described_class.serialize(value.freeze)

      expect(serialized).to eq('list' => [{ from: 1, to: 2 }, { 'deep' => { from: 1, to: 2 } }],
                               'other' => [plain, unnamed, error])
      expect([serialized, serialized.fetch('list'), serialized.fetch('list').last])
        .to all(satisfy { |part| !part.frozen? })
    end
  end

  describe '.sortable_identity' do
    it 'sorts by type, then numbers, then names, then anything else' do
      identities = [['B', 1], ['A', 10], ['A', 2], %w[A x], ['A', :y], ['A', nil], ['A', 2.5]]

      sorted = identities.sort_by { |type, id| described_class.sortable_identity(type, id) }

      expect(sorted)
        .to eq([['A', 2], ['A', 2.5], ['A', 10], %w[A x], ['A', :y], ['A', nil], ['B', 1]])
      expect(described_class.sortable_identity('A', 5)).to eq(['A', [0, 5]])
      expect(described_class.sortable_identity(:A, :y)).to eq(['A', [1, 'y']])
      expect(described_class.sortable_identity('A', nil)).to eq(['A', [2, 'nil']])
    end
  end

  describe '.row_key' do
    it "names a row by its own class's name and its id" do
      expect(described_class.row_key(FilterFeature.new(id: 5))).to eq(['FilterFeature', 5])
    end
  end

  describe '.record_identity' do
    it 'names a record by its base class, in strings' do
      expect(described_class.record_identity(FilterFeature, 5)).to eq(%w[FilterArticle 5])
    end
  end

  describe '.with_connection' do
    it "borrows a model's connection for the block, or takes the one it has" do
      borrowing = Class.new { def self.with_connection = yield(:borrowed) }
      owning = Class.new { def self.connection = :own }

      expect([borrowing, owning].map { |model| described_class.with_connection(model) { _1 } })
        .to eq(%i[borrowed own])
    end
  end

  describe '.chronological_version_key' do
    it 'keys a version by its time, then by its id padded to sort as a number' do
      expect(described_class.chronological_version_key(version.new(noon, 9)))
        .to eq([noon, "#{'0' * 31}9"])
    end
  end

  describe '.version_key' do
    it 'pads the id so that 10 sorts after 9' do
      expect(described_class.version_key(noon, 10)).to eq([noon, "#{'0' * 30}10"])
    end
  end

  describe '.chronological_sort' do
    it 'sorts versions by time, then by id' do
      versions = [version.new(noon + 1, 1), version.new(noon, 10), version.new(noon, 9)]

      expect(described_class.chronological_sort(versions).map(&:id)).to eq([9, 10, 1])
    end

    it 'refuses a tie it cannot order, naming it' do
      versions = [version.new(noon, 'a91f'), version.new(noon, '7d0c')]

      expect { described_class.chronological_sort(versions) }
        .to raise_error(PaperTrailDiff::AmbiguousVersionOrderError, /\Aversions "7d0c" and "a91f"/)
    end
  end

  describe '.ambiguous_pair' do
    it 'finds the first tie between tables, or between ids that do not count up' do
      apart = [version.new(noon, 1), version.new(noon + 1, 'a')]
      ordered = [version.new(noon, 1), version.new(noon, 2)]
      tables = [version.new(noon, 1), other_version.new(noon, 2), version.new(noon, 'b')]
      names = [version.new(noon, 'a'), version.new(noon, 'b')]

      expect([apart, ordered].map { |pair| described_class.ambiguous_pair(pair) }).to eq([nil, nil])
      expect(described_class.ambiguous_pair(tables)).to eq(tables.first(2))
      expect(described_class.ambiguous_pair(names)).to eq(names)
    end
  end

  describe '.orderable_tie?' do
    # Two version classes can share one table; one without a table is
    # matched by its class instead.
    it 'orders a tie only by ids that count up in one table' do
      same_table = Struct.new(:created_at, :id) { def self.table_name = 'versions' }
      tableless = stub_const('TablelessVersion', Struct.new(:created_at, :id))
      other_tableless = stub_const('OtherTablelessVersion', Struct.new(:created_at, :id))
      pairs = [[version.new(noon, 1), same_table.new(noon, '2')],
               [version.new(noon, 1), other_version.new(noon, 2)],
               [version.new(noon, 1), version.new(noon, 'b')],
               [version.new(noon, 'a'), version.new(noon, 2)],
               [tableless.new(noon, 1), tableless.new(noon, 2)],
               [tableless.new(noon, 1), other_tableless.new(noon, 2)]]

      expect(pairs.map { |left, right| described_class.orderable_tie?(left, right) })
        .to eq([true, false, false, false, true, false])
    end
  end

  describe '.tied_timestamp_pair' do
    it 'finds the first two versions saved in one instant, orderable or not' do
      versions = [version.new(noon, 1), version.new(noon + 1, 2), version.new(noon + 1, 3),
                  version.new(noon + 1, 4)]

      expect(described_class.tied_timestamp_pair(versions)).to eq(versions[1, 2])
      expect(described_class.tied_timestamp_pair(versions.first(2))).to be_nil
    end
  end

  describe '.versioned?' do
    it 'is true only for a model that records history' do
      model = Class.new(ActiveRecord::Base) { self.table_name = 'filter_articles' }
      unversioned = stub_const('UnversionedArticle', model)
      unset = Class.new { def self.paper_trail_options = nil }

      expect([FilterArticle, unversioned, unset, Object].map { described_class.versioned?(_1) })
        .to eq([true, false, false, false])
    end
  end

  describe '.record_id' do
    it "casts an id read from history to the type of the model's key" do
      composite = Class.new { def self.primary_key = %w[a b] }
      keyless = Class.new { def self.primary_key = nil }

      expect(['5', nil].map { |id| described_class.record_id(FilterArticle, id) }).to eq([5, nil])
      expect([composite, keyless].map { |model| described_class.record_id(model, '5') })
        .to eq(%w[5 5])
    end
  end

  describe '.limit' do
    # Active Record 8.1 casts a limit as it is set, so only a stand-in keeps
    # one as given, as earlier versions do.
    it "reads a relation's limit as Active Record writes it into SQL" do
      relation = Struct.new(:limit_value)

      expect([nil, 2, '2'].map { |value| described_class.limit(relation.new(value)) })
        .to eq([nil, 2, 2])
      expect { described_class.limit(relation.new('two')) }.to raise_error(ArgumentError)
    end
  end

  describe '.offset' do
    it "reads a relation's offset as Active Record writes it into SQL" do
      offsets = [FilterArticle.all, FilterArticle.offset(1), FilterArticle.offset('1')]

      expect(offsets.map { |relation| described_class.offset(relation) }).to eq([0, 1, 1])
    end
  end

  describe '.sequential_id?' do
    it 'is true for an integer, or a string of digits alone' do
      ids = [5, -5, '5', '05', 'a5', '5a', "5\n", 2.0, nil]

      expect(ids.map { |id| described_class.sequential_id?(id) })
        .to eq([true, true, true, true, false, false, false, false, false])
    end
  end

  describe '.ambiguous_message' do
    it 'names both versions, their instant, and what would order them' do
      pair = [version.new(noon, 'a'), version.new(noon, 'b')]

      expect(described_class.ambiguous_message(pair))
        .to eq('versions "a" and "b" share the timestamp 2032-01-01 12:00:00 UTC and have ids ' \
               'that do not order them, so their sequence cannot be recovered; record versions ' \
               'at sub-second precision or with sequential ids')
    end
  end

  describe '.compare_versions' do
    it 'compares versions by time, then by id, and refuses times that do not compare' do
      first = version.new(noon, 9)
      second = version.new(noon, 10)

      expect([[first, second], [second, first], [first, first]]
        .map { |left, right| described_class.compare_versions(left, right) }).to eq([-1, 1, 0])
      expect { described_class.compare_versions(version.new(nil, 1), first) }
        .to raise_error(PaperTrailDiff::ConfigurationError, 'versions have incomparable timestamps')
    end
  end

  describe '.association_path' do
    it 'joins a path and a name with a dot' do
      expect([['', :comments], ['comments', 'author'], ['comments', :author]]
        .map { |parent, name| described_class.association_path(parent, name) })
        .to eq(%w[comments comments.author comments.author])
    end
  end

  describe '.merge_record_groups' do
    it 'merges groups by name, joining their ids and their owners' do
      existing = { 'comments' => { model: :Comment, ids: [1, 2], owners: { 'a' => [1] } },
                   'tags' => { model: :Tag, ids: [5] } }
      incoming = { 'comments' => { model: :Note, ids: [2, 3], owners: { 'a' => [2], 'b' => [3] } },
                   'authors' => { model: :Author, ids: [7] } }

      expect(described_class.merge_record_groups(existing, incoming)).to eq(
        'comments' => { model: :Note, ids: [1, 2, 3], owners: { 'a' => [1, 2], 'b' => [3] } },
        'tags' => { model: :Tag, ids: [5] }, 'authors' => { model: :Author, ids: [7] }
      )
    end

    it 'keeps the owners either side has, and adds none where neither has them' do
      left_ids = { ids: [1] }
      right_ids = { ids: [2] }
      merged = [[{ owners: { 'a' => [1] } }, {}], [{}, { owners: { 'b' => [2] } }], [{}, {}]]
               .map do |left, right|
        described_class.merge_record_groups({ 'c' => left_ids.merge(left) },
                                            { 'c' => right_ids.merge(right) }).fetch('c')
      end

      expect(merged).to eq([{ ids: [1, 2], owners: { 'a' => [1] } },
                            { ids: [1, 2], owners: { 'b' => [2] } }, { ids: [1, 2] }])
    end
  end
end
