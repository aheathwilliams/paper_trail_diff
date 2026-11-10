# frozen_string_literal: true

require_relative '../support/filter_database'

ActiveRecord::Schema.define do
  # A version table whose ids do not count up, as a UUID column's do not.
  create_table :ends_keyed_versions, id: false, force: true do |table|
    table.string :id, primary_key: true
    table.string :item_type, null: false
    table.integer :item_id, null: false
    table.string :event, null: false
    table.integer :transaction_id
    table.datetime :created_at
  end
end

class EndsKeyedVersion < ActiveRecord::Base
  include PaperTrail::VersionConcern
end

RSpec.describe PaperTrailDiff::RecordedTransactionEnds do
  let(:noon) { Time.utc(2032, 1, 1, 12) }
  let(:recorded) { described_class.new }

  before do
    [FilterVersion, FilterJsonVersion, EndsKeyedVersion].each(&:delete_all)
    known(FilterVersion)
  end

  # The version classes loaded, as far as this example knows.
  def known(*classes)
    allow(ActiveRecord::Base).to receive(:descendants).and_return(classes)
  end

  def version(id, transaction_id, table: FilterVersion, at: id.to_i, item_id: 1)
    table.create!(id: id, item_type: 'FilterArticle', item_id: item_id, event: 'update',
                  transaction_id: transaction_id, created_at: noon + at)
  end

  # Where the transactions of the versions end, asked about on their own.
  def ends(*versions)
    recorded.call(versions) { [] }
  end

  def statements(&)
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    queries
  end

  it 'finds the last version of a transaction, of whatever record, held or not' do
    held = version(101, 7)
    last_held = version(103, 8)
    version(102, 8, item_id: 2)
    other = version(104, 7, item_id: 2)

    found = ends(held, last_held)

    expect(found.keys).to contain_exactly(['FilterVersion', 7], ['FilterVersion', 8])
    expect(found.fetch(['FilterVersion', 7])).to eq(other)
    expect(found.fetch(['FilterVersion', 7]).created_at).to eq(noon + 104)
    expect(found.fetch(['FilterVersion', 8])).to equal(last_held)
  end

  it 'reads the versions of a table in one statement, and those not held in one more' do
    held = [version(101, 7), version(102, 8), version(103, 7)]
    expect(statements { ends(*held) }.length).to eq(1)

    version(105, 9, item_id: 2)
    unfinished = version(104, 9)
    expect(statements { described_class.new.call([unfinished]) { [] } }.length).to eq(2)
  end

  it 'asks about each transaction once, along with the versions the block returns' do
    first = version(101, 7)
    second = version(102, 8)

    found = nil
    expect(statements { found = recorded.call([first]) { [second] } }.length).to eq(1)
    expect(found.keys).to contain_exactly(['FilterVersion', 7], ['FilterVersion', 8])
    expect(statements { recorded.call([first, second]) { raise 'asked again' } }).to eq([])
  end

  it 'asks nothing about versions outside a transaction' do
    alone = version(101, nil)

    expect(statements { expect(ends(alone)).to eq({}) }).to eq([])
  end

  it 'reads 500 transactions in a statement' do
    held = Array.new(501) { |index| FilterVersion.new(id: 1000 + index, transaction_id: index) }

    expect(statements { ends(*held) }.length).to eq(2)
  end

  it 'reads each version table for its own transactions' do
    known(FilterVersion, FilterJsonVersion)
    here = version(101, 7)
    there = version(102, 7, table: FilterJsonVersion)
    version(103, 7, table: FilterJsonVersion, item_id: 2)

    found = ends(here, there)

    expect(found.fetch(['FilterVersion', 7])).to equal(here)
    expect(found.fetch(['FilterJsonVersion', 7]).id).to eq(103)
  end

  # Each table's version 70 began a transaction, and both numbered it 70.
  it 'leaves out a number that transactions of two version tables took' do
    known(FilterVersion, FilterJsonVersion)
    version(70, 70)
    version(70, 70, table: FilterJsonVersion, at: 200)
    held = version(101, 70)
    version(201, 70, item_id: 2)
    version(102, 8)

    expect(ends(held, FilterVersion.find(102)).keys).to eq([['FilterVersion', 8]])
  end

  context 'with ids that do not count up' do
    def keyed(id, transaction_id, at:, item_id: 1)
      version(id, transaction_id, table: EndsKeyedVersion, at: at, item_id: item_id)
    end

    it 'finds the version a transaction saved last by when it was saved' do
      held = keyed('f', 7, at: 1)
      last_held = keyed('a', 8, at: 3)
      keyed('z', 8, at: 2, item_id: 2)
      other = keyed('b', 7, at: 4, item_id: 2)
      first = keyed('g', 9, at: 1)
      keyed('c', 9, at: 4, item_id: 2)
      last = keyed('d', 9, at: 5, item_id: 2)

      found = ends(held, last_held, first)

      expect(found.fetch(['EndsKeyedVersion', 7])).to eq(other)
      expect(found.fetch(['EndsKeyedVersion', 9])).to eq(last)
      expect(found.fetch(['EndsKeyedVersion', 8])).to equal(last_held)
    end
  end
end
