# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::OpeningTransactions do
  let(:start) { Time.utc(2032, 1, 1, 12) }

  before do
    FilterVersion.delete_all
    FilterJsonVersion.delete_all
  end

  # A version saved `minutes` from the start, of any record.
  def version(minutes, transaction_id, table: FilterVersion, item_id: 1)
    table.create!(item_type: 'FilterArticle', item_id: item_id, event: 'update',
                  transaction_id: transaction_id, created_at: start + (minutes * 60))
  end

  # Each prepared series holds the versions of one record it read.
  def opening(*held)
    series = Struct.new(:versions)
    by_record = held.each_with_index.to_h { |versions, index| [[index.to_s], series.new(versions)] }
    described_class.new(by_record, start).call
  end

  def statements(&)
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    queries
  end

  # Saved before the start: transactions 7, 8 and 9, of which 8 began
  # earliest, one more of 7, one of a transaction no held version is in, and
  # one outside any transaction.
  it 'finds the transactions held versions belong to that saved a version before the start' do
    [[-2, 7], [-1, 7], [-4, 8], [-3, 9], [-6, 5], [-5, nil]].each do |minutes, transaction|
      version(minutes, transaction, item_id: 2)
    end
    held = [version(3, nil), version(-1, 8), version(0, 7), version(1, 8), version(2, 9),
            version(4, 10)]

    keys, began = opening(held)

    expect(keys).to contain_exactly(['FilterVersion', 7], ['FilterVersion', 8],
                                    ['FilterVersion', 9])
    expect(began).to eq(start - 240)
  end

  it 'finds none when every transaction began at the start or after it' do
    version(0, 7, item_id: 2)

    expect(opening([version(0, 7), version(1, 8)])).to be_nil
  end

  # Each version table numbers its own transactions.
  it 'reads each version table for its own transactions' do
    version(-1, 7, table: FilterJsonVersion, item_id: 2)
    held = [version(0, 7), version(1, 7, table: FilterJsonVersion)]

    expect(opening(held)).to eq([[['FilterJsonVersion', 7]], start - 60])
  end

  it 'ignores versions held from before the start' do
    version(-2, 7, item_id: 2)

    expect(opening([version(-1, 7)])).to be_nil
  end

  it 'reads each transaction once, in statements of a fixed number of them' do
    stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 2)
    held = [version(0, 7), version(1, 7), version(2, 7), version(3, 8), version(4, 9)]

    expect(statements { opening(held[0, 3], held[3, 2]) }.length).to eq(2)
  end
end
