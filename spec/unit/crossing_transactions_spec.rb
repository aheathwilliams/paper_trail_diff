# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::CrossingTransactions do
  let(:start) { Time.utc(2032, 1, 1, 12) }

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

  def reach(tables: [FilterVersion]) = described_class.reach(tables, start)

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

    it 'finds where the earliest began, whatever records they saved' do
      version(0, 8, item_id: 2)
      version(12, 7, item_id: 2)

      expect(reach).to eq(at(-4))
    end

    it 'finds none when no transaction saved on both sides of the start, or without a start' do
      expect(reach).to be_nil
      version(0, 8, item_id: 2)
      expect(described_class.reach([FilterVersion], nil)).to be_nil
    end

    it 'reads each version table for its own transactions' do
      version(1, 5, table: FilterJsonVersion)
      version(-3, 9, table: FilterJsonVersion)
      version(1, 9, table: FilterJsonVersion)

      expect(reach(tables: [FilterVersion, FilterJsonVersion])).to eq(at(-3))
      expect(reach(tables: [])).to be_nil
    end

    it 'reads each table in one statement, however many transactions are open' do
      version(0, 8, item_id: 2)
      version(1, 7, item_id: 2)

      expect(statements { reach }.length).to eq(1)
      expect(statements { reach(tables: [FilterVersion, FilterJsonVersion]) }.length).to eq(2)
    end

    it 'does not look up a version that began its transaction' do
      FilterVersion.create!(id: 7, item_type: 'FilterArticle', item_id: 2, event: 'update',
                            transaction_id: 7, created_at: at(1))

      expect(reach).to be_nil
    end

    it 'reads the models that PaperTrail tracks, by name' do
      version(0, 8, item_id: 2)

      expect(described_class.open_among(%w[FilterArticle String], start)).to eq(at(-4))
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

      expect(reach).to eq(at(-1))
    end

    it 'finds none when the later one began at the start' do
      first_version(0, FilterJsonVersion)
      version(1, 70, item_id: 2)

      expect(reach).to be_nil
    end
  end
end
