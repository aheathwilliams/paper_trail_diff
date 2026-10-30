# frozen_string_literal: true

require_relative '../support/version_table_database'

RSpec.describe PaperTrailDiff::VersionTable do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    ShelfVersion.delete_all
    [ShelfBook, Shelf, DefaultShelfBook, DefaultShelf].each(&:delete_all)
  end

  # Two shelves; a book is renamed alongside its shelf, then moves to the other.
  def history(shelf_class)
    first, second = %w[First Second].map do |title|
      shelf_class.transaction { shelf_class.create!(title: title) }
    end
    book = shelf_class.transaction { first.books.create!(title: 'Draft') }
    shelf_class.transaction do
      book.update!(title: 'Final')
      first.update!(title: 'First, sorted')
    end
    shelf_class.transaction { book.update!(shelf: second) }
    shelf_class.transaction { first.update!(title: 'First, empty') }
    [first.reload, second.reload]
  end

  def changes(attributes)
    attributes.to_h { |name, change| [name, [change.from, change.to]] }
  end

  # The diffs without what names the tables or models apart.
  def readable(steps)
    steps.reject(&:empty?).map do |step|
      books = step.diff.associations['books']
      [changes(step.diff.attributes),
       books && { added: books.added.map { |book| book.attributes['title'] },
                  removed: books.removed.map { |book| book.attributes['title'] },
                  changed: books.changed.map { |change| changes(change.attributes) } }]
    end
  end

  def reads(shelf_class)
    first, second = history(shelf_class)
    window = first.versions.minimum(:created_at)..Time.now.utc
    [first, second].flat_map do |shelf|
      batch = PaperTrailDiff.analyze_many([shelf], within: window, associations: [:books],
                                                   activity: true)
      [readable(PaperTrailDiff.activity_timeline(shelf, associations: [:books])),
       readable(PaperTrailDiff.timeline(shelf, associations: [:books])),
       readable(batch.values.first.activity_timeline)]
    end
  end

  it 'reads a root and its association from one version table other than the default' do
    custom = reads(Shelf)

    expect(custom).to eq(reads(DefaultShelf))
    expect(custom.first).to include([{}, { added: [], removed: ['Final'], changed: [] }])
    renamed = { added: [], removed: [], changed: [{ 'title' => %w[Draft Final] }] }
    expect(custom.first).to include([{ 'title' => ['First', 'First, sorted'] }, renamed])
  end

  it "refuses an association whose target keeps versions in another table than its owner's" do
    shelf = SplitShelf.create!(title: 'Split')

    expect { PaperTrailDiff.activity_timeline(shelf, associations: [:books]) }
      .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                      'unsupported association books: SplitShelf#books keeps versions in ' \
                      'versions and version_associations but SplitShelfBook in shelf_versions ' \
                      'and version_associations, and association history is read from one set ' \
                      'of version tables')
  end

  it "refuses an association whose owner keeps versions in another table than its target's" do
    book = SplitShelfBook.create!(title: 'Loose')

    expect { PaperTrailDiff.timeline(book, associations: [:shelf]) }
      .to raise_error(PaperTrailDiff::UnsupportedAssociationError,
                      /SplitShelfBook#shelf keeps versions in shelf_versions/)
  end

  describe '.unsupported_reason' do
    def reason(model, name)
      described_class.unsupported_reason(model.reflect_on_association(name))
    end

    it 'names the part of a through whose ends keep versions apart' do
      expect(reason(SplitShelf, :notes))
        .to start_with('SplitShelf#books keeps versions in versions')
      expect(reason(Shelf, :default_shelves))
        .to start_with('ShelfBook#default_shelf keeps versions in shelf_versions')
    end

    it 'accepts a through whose parts keep versions together' do
      expect(reason(Shelf, :notes)).to be_nil
    end

    it 'accepts an association with an unversioned or polymorphic end' do
      expect(reason(LooseShelf, :books)).to be_nil
      expect(reason(LooseShelfBook, :shelf)).to be_nil
      expect(reason(LooseShelfBook, :holder)).to be_nil
    end

    it 'names a HABTM whose target keeps versions apart' do
      expect(reason(SplitShelf, :labels))
        .to start_with('SplitShelf#labels keeps versions in versions')
    end
  end

  describe '.joined' do
    it 'pairs each version association row with the version it was saved with' do
      first, second = %w[First Second].map { |title| Shelf.create!(title: title) }
      rows = [first, second].map do |shelf|
        PaperTrail::VersionAssociation.create!(
          version_id: shelf.versions.last.id, foreign_key_name: 'shelf_id', foreign_key_id: shelf.id
        )
      end

      joined = described_class.joined(PaperTrail::VersionAssociation, ShelfVersion).where(id: rows)
      pairs = joined.pluck(:foreign_key_id, ShelfVersion.arel_table[:item_id])

      expect(pairs).to contain_exactly([first.id, first.id], [second.id, second.id])
    end
  end

  it 'leaves the association out of the paths it lists' do
    expect(PaperTrailDiff.association_paths(SplitShelf).map(&:path)).not_to include('books')
    expect(PaperTrailDiff.association_paths(Shelf).map(&:path)).to include('books')
  end
end
