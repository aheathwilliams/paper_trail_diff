# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::TransactionAnchors do
  let(:noon) { Time.utc(2032, 1, 1, 12) }
  let(:start) { noon }

  before do
    FilterVersion.delete_all
    FilterJsonVersion.delete_all
    known(FilterVersion, FilterJsonVersion)
  end

  # The version classes loaded, as far as this example knows.
  def known(*classes)
    allow(ActiveRecord::Base).to receive(:descendants).and_return(classes)
  end

  def version(id, seconds, transaction_id, table: FilterVersion)
    table.create!(id: id, item_type: 'FilterArticle', item_id: 1, event: 'update',
                  transaction_id: transaction_id, created_at: noon + seconds)
  end

  def kept
    described_class.scope(FilterVersion.all, FilterVersion, start).order(:id).pluck(:id)
  end

  describe '.unbroken' do
    it 'is nothing when the version table is the only one' do
      known(FilterVersion, Class.new(FilterVersion))

      expect(described_class.unbroken(FilterVersion, start)).to be_nil
      expect(described_class.scope(FilterVersion.all, FilterVersion, start))
        .to eq(FilterVersion.all)
    end

    it 'leaves out a class that is not a version table of this database with such ids' do
      model = Class.new(ActiveRecord::Base) { self.table_name = 'filter_articles' }
      abstract = Class.new(FilterJsonVersion) { self.abstract_class = true }
      missing = Class.new(FilterJsonVersion) { self.table_name = 'filter_missing_versions' }
      known(FilterVersion, model, abstract, missing)

      expect(described_class.unbroken(FilterVersion, start)).to be_nil
    end

    it 'leaves out a version table whose ids are of another type than the number' do
      allow(FilterJsonVersion).to receive(:type_for_attribute).and_call_original
      allow(FilterJsonVersion).to receive(:type_for_attribute).with('id')
                                                              .and_return(ActiveRecord::Type::String.new)

      expect(described_class.unbroken(FilterVersion, start)).to be_nil
    end
  end

  describe '.scope' do
    # Transaction 70 began here at -10 s, and another began in the other
    # table at -5 s.
    before do
      version(70, -10, 70)
      version(71, -8, 70)
      version(70, -5, 70, table: FilterJsonVersion)
      version(72, -3, 70)
      version(73, 2, 70)
    end

    it 'keeps the versions no first version of their number separates from the start' do
      expect(kept).to eq([72, 73])
    end

    it 'keeps the versions after the start up to the next first version' do
      version(71, 4, 71, table: FilterJsonVersion)
      version(74, 3, 71)
      version(75, 4, 71)
      version(76, 5, 71)

      expect(kept).to eq([72, 73, 74])
    end

    it 'counts a first version at the start as after it' do
      version(80, -1, 80)
      version(80, 0, 80, table: FilterJsonVersion)
      version(81, 1, 80)

      expect(kept).to eq([72, 73, 80])
    end

    it 'keeps a version saved at the instant of a first version before the start' do
      version(90, -2, 90, table: FilterJsonVersion)
      version(91, -2, 90)

      expect(kept).to include(91)
    end

    it 'separates by a first version of the table itself' do
      version(95, -2, 60)
      version(60, 1, 60)
      version(96, 2, 60)

      expect(kept).to eq([72, 73, 95])
    end
  end

  describe '.shared' do
    it 'names the numbers that first versions of more than one table carry' do
      version(70, 0, 70)
      version(70, 5, 70, table: FilterJsonVersion)
      version(71, 1, 71)
      version(72, 2, 71, table: FilterJsonVersion)
      version(73, 3, 73, table: FilterJsonVersion)
      version(74, 4, 70)

      expect(described_class.shared(FilterVersion, [70, 71, 72, 73, 74])).to eq([70])
      expect(described_class.shared(FilterVersion, [71])).to eq([])
    end

    it 'names none, and reads nothing, when the version table is the only one' do
      known(FilterVersion)
      version(70, 0, 70)

      allow(FilterVersion).to receive(:where)
      expect(described_class.shared(FilterVersion, [70])).to eq([])
      expect(FilterVersion).not_to have_received(:where)
    end
  end

  describe '.continued' do
    def continued(ids)
      saved = FilterVersion.where(FilterVersion.arel_table[:created_at].lt(noon))
      described_class.continued(saved, FilterVersion, start, ids).order(:id).pluck(:id)
    end

    # Transaction 60 began in the other table at -5 s, and another began
    # here at 4 s.
    before do
      version(60, -5, 60, table: FilterJsonVersion)
      version(72, -3, 60)
      version(73, 2, 60)
      version(60, 4, 60)
      version(74, 5, 60)
      version(75, -1, 75)
    end

    it 'keeps the versions of the transactions the later versions are in' do
      expect(continued([73])).to eq([72])
      expect(continued([74])).to eq([])
    end

    it 'keeps every version of the numbers where the version table is the only one' do
      known(FilterVersion)
      saved = FilterVersion.where(transaction_id: 60)

      expect(described_class.continued(saved, FilterVersion, start, [74])).to eq(saved)
    end
  end
end
