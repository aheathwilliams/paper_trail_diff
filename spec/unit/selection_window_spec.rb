# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::SelectionWindow do
  let(:start) { Time.utc(2032, 1, 1, 12) }
  let(:window) { PaperTrailDiff::TimeRange.new(start.., digits: 3) }
  let(:selection) { described_class.new(window, at(-10)) }

  before { FilterVersion.delete_all }

  def at(minutes) = start + (minutes * 60)

  def version(minutes, transaction_id, item_id: 1)
    FilterVersion.create!(item_type: 'FilterArticle', item_id: item_id, event: 'update',
                          transaction_id: transaction_id, created_at: at(minutes))
  end

  it 'reaches back as far as it is widened, keeping the edge digits of its window' do
    expect(selection.to_range.begin).to eq(at(-10))
    expect(selection.digits).to eq(3)
  end

  # Transaction 7 saved on both sides of the start; 5 and the version
  # outside any transaction only before it, and 9 only from it onward.
  it 'selects by its window and by what the transactions open at its start saved before it' do
    crossing_before = version(-2, 7)
    version(-3, 5)
    version(-1, nil)
    crossing_after = version(1, 7)
    later = version(2, 9)
    untracked = version(3, nil)

    expect(selection.scope(FilterVersion.all))
      .to contain_exactly(crossing_before, crossing_after, later, untracked)
  end

  # The relation narrows what is selected, not which transactions cross.
  it 'finds the transactions open at its start among every version of the table' do
    crossing_before = version(-2, 7)
    version(1, 7, item_id: 2)

    expect(selection.scope(FilterVersion.where(item_id: 1))).to eq([crossing_before])
  end

  it 'selects by its window alone in a version table without transactions' do
    allow(FilterVersion).to receive(:column_names)
      .and_return(FilterVersion.columns.map(&:name) - ['transaction_id'])

    expect(selection.scope(FilterVersion.all).to_sql).to eq(window.scope(FilterVersion.all).to_sql)
  end
end
