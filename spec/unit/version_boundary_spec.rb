# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::VersionBoundary do
  let(:noon) { Time.utc(2032, 1, 1, 12) }
  let(:instant) { Struct.new(:created_at).new(noon) }

  # A version table whose ids are not sequential.
  let(:uuid_version) do
    Struct.new(:id, :created_at, :item_type) do
      def self.table_name = 'uuid_versions'
    end
  end

  before do
    FilterVersion.delete_all
    FilterJsonVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  # One article's versions, created and then updated, each at the given
  # minute past noon and in the given transaction.
  def versions(*minutes, transactions: [])
    article = FilterArticle.create!(title: 'Draft')
    minutes.drop(1).each_with_index { |_, index| article.update!(title: "Edit #{index}") }
    rows = FilterVersion.where(item_id: article.id).order(:id).to_a
    rows.zip(minutes, transactions).map do |version, minute, transaction|
      version.update_columns(created_at: noon + (minute * 60), transaction_id: transaction)
      version
    end
  end

  # A version in the other version table, with the given id.
  def json_version(id, minute: 0)
    FilterJsonVersion.create!(id: id, item_type: 'FilterArticle', item_id: 1, event: 'update',
                              created_at: noon + (minute * 60))
  end

  describe '.at_or_after?' do
    it 'orders versions by time' do
      earlier, later = versions(0, 1)

      expect(described_class.at_or_after?(later, earlier)).to be(true)
      expect(described_class.at_or_after?(earlier, later)).to be(false)
    end

    it 'orders by time alone versions of two tables, or whose ids do not count up' do
      version, = versions(0)
      other = json_version(version.id + 100, minute: 1)
      early = uuid_version.new('a91f', noon, 'FilterArticle')
      late = uuid_version.new('7d0c', noon + 60, 'FilterArticle')

      expect(described_class.at_or_after?(other, version)).to be(true)
      expect(described_class.at_or_after?(version, other)).to be(false)
      expect(described_class.at_or_after?(late, early)).to be(true)
      expect(described_class.at_or_after?(early, late)).to be(false)
    end

    it 'places versions by time against a boundary that is not a version' do
      earlier, later = versions(0, 1)
      boundary = Struct.new(:created_at).new(noon + 30)

      expect([earlier, later].map { |version| described_class.at_or_after?(version, boundary) })
        .to eq([false, true])
    end

    it 'orders versions saved in one instant by id' do
      first, second = versions(0, 0)

      expect(described_class.at_or_after?(second, first)).to be(true)
      expect(described_class.at_or_after?(first, second)).to be(false)
    end

    # Each boundary below lacks one thing a version has: an id, an
    # item_type, or a table.
    it 'keeps every version saved in the instant a boundary that is not a version names' do
      first, second = versions(0, 0)
      record = FilterArticle.new(id: first.item_id, created_at: noon)
      no_id = Struct.new(:created_at, :item_type) { def self.table_name = 'filter_versions' }
      no_table = Struct.new(:id, :created_at, :item_type)

      [instant, record, no_id.new(noon, 'FilterArticle'),
       no_table.new(first.id, noon, 'FilterArticle')].each do |boundary|
        expect([first, second].map { |version| described_class.at_or_after?(version, boundary) })
          .to eq([true, true])
      end
    end

    it 'places a version at itself, even where ids do not order versions' do
      version, = versions(0)

      expect(described_class.at_or_after?(version, FilterVersion.find(version.id))).to be(true)
      expect(described_class.at_or_after?(uuid_version.new('7d0c', noon, 'FilterArticle'),
                                          uuid_version.new('7d0c', noon, 'FilterArticle')))
        .to be(true)
    end

    it 'refuses a tie between version tables or ids that do not count up, naming both' do
      version, = versions(0)
      other = json_version(version.id + 100)
      boundary = uuid_version.new('7d0c', noon, 'FilterArticle')

      expect { described_class.at_or_after?(other, version) }
        .to raise_error(PaperTrailDiff::AmbiguousVersionOrderError,
                        /\Aversions #{version.id} and #{other.id} share the timestamp/)
      expect do
        described_class.at_or_after?(uuid_version.new('a91f', noon, 'FilterArticle'), boundary)
      end.to raise_error(PaperTrailDiff::AmbiguousVersionOrderError, /\Aversions "7d0c" and "a91f"/)
    end
  end

  describe '.transaction_start' do
    # The first version stands in for a child's, saved earlier in the
    # transaction of the root's first version in range, as the update behind a
    # touch: true parent version is.
    it "moves the start back to the earliest version of each root's first transaction" do
      child, = versions(0, transactions: [7])
      earlier, root, later = versions(1, 3, 4, transactions: [5, 7, 9])

      expect(described_class.transaction_start([later, root, earlier], root.created_at))
        .to eq(child.created_at)
    end

    it "finds each root's first version in range by time, not by id" do
      child, = versions(0, transactions: [7])
      later, first = versions(4, 3, transactions: [9, 7])

      expect(described_class.transaction_start([later, first], noon + 120))
        .to eq(child.created_at)
    end

    it 'reads the first transaction of every root' do
      child, = versions(0, transactions: [8])
      first_root, = versions(2, transactions: [7])
      second_root, = versions(3, transactions: [8])

      expect(described_class.transaction_start([first_root, second_root], noon + 120))
        .to eq(child.created_at)
    end

    it 'reads only the first transaction of each root at or after the start' do
      versions(0, transactions: [9])
      root, later = versions(2, 3, transactions: [7, 9])

      expect(described_class.transaction_start([root, later], noon + 120)).to eq(noon + 120)
    end

    it 'keeps the start when no transaction opens before it' do
      early, late = versions(0, 2)
      root, = versions(2, transactions: [7])

      expect(described_class.transaction_start([early, late], noon + 60)).to eq(noon + 60)
      expect(described_class.transaction_start([root], noon + 90)).to eq(noon + 90)
      expect(described_class.transaction_start([], noon)).to eq(noon)
      expect(described_class.transaction_start([early, late], nil)).to be_nil
    end

    it 'keeps the start when the transaction left no versions to read' do
      root, = versions(1, transactions: [7])
      FilterVersion.delete_all

      expect(described_class.transaction_start([root], noon)).to eq(noon)
    end

    # The earliest start is in the second of four slices, and the last slice
    # reads nothing.
    it 'reads the transactions in slices, taking the earliest start of any' do
      stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 2)
      first_root, = versions(2, transactions: [7])
      second_root, = versions(3, transactions: [8])
      gone, = versions(4, transactions: [6])
      child, = versions(0, transactions: [9])
      third_root, = versions(5, transactions: [9])
      fourth_root, = versions(6, transactions: [10])
      gone_alone, = versions(7, transactions: [5])
      gone_too, = versions(8, transactions: [4])
      [gone, gone_alone, gone_too].each(&:delete)
      roots = [first_root, second_root, gone, third_root, fourth_root, gone_alone, gone_too]
      statements = []
      count = ->(*, payload) { statements << payload[:sql] if payload[:sql].include?('MIN(') }

      start = ActiveSupport::Notifications.subscribed(count, 'sql.active_record') do
        described_class.transaction_start(roots, noon + 120)
      end

      expect(start).to eq(child.created_at)
      expect(statements.length).to eq(4)
    end
  end

  describe '.transaction_id' do
    it "reads a version's transaction, or nil where its class has none" do
      inside, outside = versions(0, 1, transactions: [7])

      expect([inside, outside].map { |version| described_class.transaction_id(version) })
        .to eq([7, nil])
      expect(described_class.transaction_id(uuid_version.new('7d0c', noon, 'FilterArticle')))
        .to be_nil
    end
  end

  describe '.same_version?' do
    it 'is true only for the same row of the same version table' do
      first, second = versions(0, 1)

      expect(described_class.same_version?(first, FilterVersion.find(first.id))).to be(true)
      expect(described_class.same_version?(first, second)).to be(false)
      expect(described_class.same_version?(first, json_version(first.id))).to be(false)
      expect(described_class.same_version?(first, instant)).to be(false)
      expect(described_class.same_version?(instant, first)).to be(false)
    end
  end
end
