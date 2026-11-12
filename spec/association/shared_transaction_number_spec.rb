# frozen_string_literal: true

require_relative '../support/version_table_database'

# PaperTrail numbers a transaction by the id of the first version it saved,
# in whichever version table that was. A transaction that saved a shelf first
# takes its number from `shelf_versions`, and writes it on the versions it
# goes on to save in `versions`, where a version with that id named its own
# transaction long before. The two share a number and nothing else.
RSpec.describe 'Transactions numbered alike from different version tables' do
  let(:march) { Time.utc(2026, 3, 1) }
  let(:june) { Time.utc(2026, 6, 10, 12) }
  let(:bystander) { DefaultShelf.create!(title: 'bystander') }
  let(:shelf) { DefaultShelf.create!(title: 'draft') }
  let(:book) { shelf.books.create!(title: 'book') }

  before do
    PaperTrail::VersionAssociation.delete_all
    [PaperTrail::Version, ShelfVersion, DefaultShelfBook, DefaultShelf, Shelf].each(&:delete_all)
    stamp(saved { bystander }, Time.utc(2026, 1, 10))
    stamp(saved { book }, march)
    stamp(saved { shelf.update!(title: 'march') }, march + 86_400)
    renumber(saved { yield_june }, PaperTrail::Version.find_by!(item_id: bystander.id).id)
  end

  # The June transaction saves a shelf of the other table first, then the
  # book, then the shelf.
  def yield_june
    DefaultShelf.transaction do
      Shelf.create!(title: 'elsewhere')
      book.update!(title: 'june book')
      shelf.update!(title: 'june')
    end
  end

  # The versions a block saves in PaperTrail's table.
  def saved
    last = PaperTrail::Version.maximum(:id) || 0
    yield
    PaperTrail::Version.where(id: (last + 1)..)
  end

  def stamp(versions, time)
    versions.update_all(created_at: time)
  end

  # Gives the June transaction the number of the bystander's, as it has when
  # the two tables' ids happen to meet.
  def renumber(versions, number)
    versions.update_all(transaction_id: number, created_at: june)
    # SQL Server cannot update an identity column, so the row is saved
    # again under the number.
    ShelfVersion.find_each do |version|
      row = version.attributes.merge('id' => number, 'transaction_id' => number,
                                     'created_at' => june - 1)
      version.delete
      ShelfVersion.insert_all!([row])
    end
  end

  def titles(analysis)
    analysis.timeline.flat_map { |step| step.diff.attributes.slice('title').values.map(&:to) }
  end

  def analyses(within)
    options = { within: within, associations: [:books] }
    [PaperTrailDiff.analyze(shelf.reload, **options),
     PaperTrailDiff.analyze_many([shelf.reload], **options).values.first]
  end

  it 'shares a number between the two' do
    expect(PaperTrail::Version.where(transaction_id: ShelfVersion.select(:id)).pluck(:created_at))
      .to contain_exactly(Time.utc(2026, 1, 10), june, june)
  end

  it 'leaves the start of a window before the later one where it was asked for' do
    analyses(Time.utc(2026, 6, 1)..Time.utc(2026, 7, 1)).each do |analysis|
      expect(analysis.window.begin).to eq(Time.utc(2026, 6, 1))
      expect(titles(analysis)).to eq(['june'])
    end
  end

  it 'leaves the end of a window before the later one where it was asked for' do
    analyses((march + 3600)...Time.utc(2026, 6, 1)).each do |analysis|
      expect(analysis.window.end).to eq(Time.utc(2026, 6, 1))
      expect(titles(analysis)).to eq(['march'])
    end
  end

  # The start is inside the June transaction, which began a second before
  # the versions it saved here.
  it 'still moves a start inside the later one to where it began here' do
    analyses((june - 0.5)..).each do |analysis|
      expect(titles(analysis)).to eq(['june'])
    end
  end

  it 'reads the history of a window from its start, not from the earlier one' do
    expect(PaperTrailDiff::TransactionCut.range_start(shelf.versions.to_a, june)).to eq(june)
  end

  it 'selects no record for a window by the earlier one' do
    selected = PaperTrailDiff.analyze_scope(
      DefaultShelf.all, limit: 10, associations: [:books],
                        within: Time.utc(2026, 6, 1)..Time.utc(2026, 7, 1)
    )

    expect(selected.analyses.keys.map(&:last)).to eq([shelf.id.to_s])
  end
end
