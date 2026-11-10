# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::CrossingTransactions do
  let(:start) { Time.utc(2032, 1, 1, 12) }
  let(:finish) { start + 600 }

  before do
    FilterVersion.delete_all
    FilterJsonVersion.delete_all
  end

  def at(minutes) = start + (minutes * 60)

  # A version saved `minutes` from the start, of any record. Its id is above
  # the transactions' numbers, so none is the first version of one.
  def version(minutes, transaction_id, table: FilterVersion, item_id: 1)
    id = [table.maximum(:id).to_i, 100].max + 1
    table.create!(id: id, item_type: 'FilterArticle', item_id: item_id, event: 'update',
                  transaction_id: transaction_id, created_at: at(minutes))
  end

  # The first version of transaction 70, which carries its own id.
  def first_version(minutes, table)
    table.create!(id: 70, item_type: 'FilterArticle', item_id: 3, event: 'update',
                  transaction_id: 70, created_at: at(minutes))
  end

  # Each prepared series holds the versions of one record it read.
  def reach(*held, tables: [FilterVersion], finish: self.finish)
    series = Struct.new(:versions)
    by_record = held.each_with_index.to_h { |versions, index| [[index.to_s], series.new(versions)] }
    described_class.new(by_record, tables, start, finish).call
  end

  def statements(&)
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    queries
  end

  describe 'the transactions open at the start' do
    # Transactions 7 and 8 saved on both sides of the start, 8 first and 7
    # last; 5 only before it, 9 only from it onward, and one version before
    # it outside any transaction.
    before do
      [[-2, 7], [-4, 8], [-6, 5], [-5, nil], [0, 9], [1, 9]].each do |minutes, transaction|
        version(minutes, transaction, item_id: 2)
      end
    end

    it 'finds where the earliest began, whatever records they saved, and where the latest ended' do
      version(0, 8, item_id: 2)
      version(12, 7, item_id: 2)

      expect(reach).to eq([at(-4), at(12)])
    end

    it 'says nothing of an end inside the window, or at its end' do
      version(0, 8, item_id: 2)
      version(10, 7, item_id: 2)

      expect(reach).to eq([at(-4), nil])
      expect(reach(finish: nil)).to eq([at(-4), nil])
    end

    it 'finds none when no transaction saved on both sides of the start' do
      expect(reach).to eq([nil, nil])
    end

    it 'reads each version table for its own transactions' do
      version(1, 5, table: FilterJsonVersion)
      version(-3, 9, table: FilterJsonVersion)
      version(1, 9, table: FilterJsonVersion)

      expect(reach(tables: [FilterVersion, FilterJsonVersion])).to eq([at(-3), nil])
      expect(reach(tables: [])).to eq([nil, nil])
    end

    it 'reads the ends of the open transactions in statements of a fixed number of them' do
      stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 1)
      version(0, 8, item_id: 2)
      version(1, 7, item_id: 2)

      expect(statements { reach }.length).to eq(3)
      FilterVersion.where(created_at: start..).delete_all
      expect(statements { reach }.length).to eq(1)
    end

    it 'does not look up a version that began its transaction' do
      FilterVersion.create!(id: 7, item_type: 'FilterArticle', item_id: 2, event: 'update',
                            transaction_id: 7, created_at: at(1))

      expect(reach).to eq([nil, nil])
    end
  end

  # A transaction's first version carries its own id as its number, in
  # whichever table saved it, so another table can number a transaction as
  # this one numbered an earlier one (see TransactionAnchors).
  context 'when another table numbered a transaction as this one had' do
    before { first_version(-10, FilterVersion) }

    it 'reads the versions of the one open at the start' do
      first_version(-2, FilterJsonVersion)
      version(-1, 70, item_id: 2)
      version(1, 70, item_id: 2)

      expect(reach).to eq([at(-1), nil])
    end

    it 'finds none when the later one began at the start' do
      first_version(0, FilterJsonVersion)
      version(1, 70, item_id: 2)

      expect(reach).to eq([nil, nil])
    end
  end

  describe 'the transactions across the end' do
    it 'finds where the latest of those held up to the end saved its last version' do
      held = [version(1, 7), version(2, 8), version(10, 9), version(3, nil)]
      [[11, 7], [14, 8], [13, 8], [15, 9], [16, 5]].each do |minutes, transaction|
        version(minutes, transaction, item_id: 2)
      end

      expect(reach(held)).to eq([nil, at(15)])
    end

    it 'ignores versions held from before the start or after the end, and an endless window' do
      held = [version(-1, 7), version(11, 8)]
      version(12, 7, item_id: 2)
      version(13, 8, item_id: 2)

      expect(reach(held, tables: [])).to eq([nil, nil])
      expect(reach([version(1, 7)], finish: nil)).to eq([at(-1), nil])
    end

    it 'reads each version table for its own transactions' do
      version(12, 7, table: FilterJsonVersion, item_id: 2)
      version(11, 7, item_id: 2)

      expect(reach([version(1, 7)], [version(2, 7, table: FilterJsonVersion)]))
        .to eq([nil, at(12)])
    end

    it 'reads each transaction once, in statements of a fixed number of them' do
      stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 2)
      held = [version(1, 7), version(2, 7), version(3, 7), version(4, 8), version(5, 9)]

      expect(statements { reach(held[0, 3], held[3, 2], tables: []) }.length).to eq(2)
    end

    it 'reads the versions of the transaction a held version is in' do
      first_version(-10, FilterVersion)
      first_version(11, FilterJsonVersion)
      version(12, 70, item_id: 2)

      expect(reach([version(1, 70)]).last).to be_nil
    end
  end
end
