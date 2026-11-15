# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::TransactionCut do
  let(:noon) { Time.utc(2032, 1, 1, 12) }

  before { FilterVersion.delete_all }

  def at(minutes) = noon + (minutes * 60)

  # A version of any article, saved `minutes` past noon. Its id is above the
  # transactions' numbers, so none is the first version of one.
  def version(minutes, transaction_id, item_id: 1)
    id = [FilterVersion.maximum(:id).to_i, 100].max + 1
    FilterVersion.create!(id: id, item_type: 'FilterArticle', item_id: item_id, event: 'update',
                          transaction_id: transaction_id, created_at: at(minutes))
  end

  describe '.range_end' do
    it "is the last version the version's transaction saved, of any record" do
      first = version(0, 7)
      last = version(2, 7, item_id: 2)
      version(3, 8)

      expect(described_class.range_end(first)).to eq(last)
      expect(described_class.range_end(last)).to eq(last)
    end

    it 'is the version itself outside a transaction, or where none is read' do
      alone = version(0, nil)
      shared = version(1, 7)
      version(2, 7)
      allow(PaperTrailDiff::TransactionAnchors).to receive(:shared).and_return([7])

      expect(described_class.range_end(alone)).to equal(alone)
      expect(described_class.range_end(shared)).to equal(shared)
    end
  end

  describe '.ends_at' do
    it 'is the latest time any of the transactions takes effect, or any version is saved' do
      inside = version(0, 7)
      version(5, 7, item_id: 2)
      loose = version(3, nil)

      expect(described_class.ends_at([inside, loose])).to eq(at(5))
      expect(described_class.ends_at([loose])).to eq(at(3))
      expect(described_class.ends_at([inside, version(9, nil)])).to eq(at(9))
      expect(described_class.ends_at([])).to be_nil
    end
  end

  describe '.crossing_start' do
    let(:traversal) do
      instance_double(PaperTrailDiff::AssociationTraversal, path_types: [])
    end

    it 'moves the start back to where a transaction open there began' do
      version(-3, 7)
      version(1, 7)

      expect(described_class.crossing_start(FilterArticle, traversal, at(0))).to eq(at(-3))
      expect(described_class.crossing_start(FilterArticle, traversal, at(2))).to eq(at(2))
      expect(described_class.crossing_start(FilterArticle, traversal, nil)).to be_nil
    end
  end
end
