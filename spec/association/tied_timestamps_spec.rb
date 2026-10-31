# frozen_string_literal: true

require_relative '../support/association_database'

# A database storing whole seconds, or a burst of writes inside one tick, gives
# many versions the same created_at. Their ids still record the order.
RSpec.describe 'Association history with tied version timestamps' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
  end

  def bodies(records)
    records.map { |record| record.attributes.fetch('body') }
  end

  def summary(diff)
    comments = diff.associations.fetch('comments') do
      PaperTrailDiff::CollectionAssociationDiff.new(
        kind: :has_many, added: [], removed: [], changed: []
      )
    end
    {
      title: diff.attributes['title']&.to,
      added: bodies(comments.added), removed: bodies(comments.removed),
      changed: comments.changed.map { |change| change.attributes.fetch('body').to }
    }
  end

  def create_history
    article = TrackedArticle.create!(title: 'v1')
    first = article.comments.create!(body: 'first')
    article.update!(title: 'v2')
    first.update!(body: 'first edited')
    article.comments.create!(body: 'second')
    article.update!(title: 'v3')
    first.destroy!
    article.update!(title: 'v4')
    article.reload
  end

  let(:expected_steps) do
    [
      { title: nil, added: [], removed: [], changed: [] },
      { title: 'v2', added: ['second'], removed: [], changed: ['first edited'] },
      { title: 'v3', added: [], removed: ['first edited'], changed: [] },
      { title: 'v4', added: [], removed: [], changed: [] }
    ]
  end

  context 'when every version shares one timestamp' do
    before do
      instant = Time.utc(2026, 1, 1, 12)
      allow(AssociationSpecVersionClock).to receive(:next).and_return(instant)
    end

    it 'orders same-instant versions by id' do
      article = create_history

      expect(PaperTrail::Version.distinct.count(:created_at)).to eq(1)
      expect(PaperTrailDiff.timeline(article, from: :first, to: article, associations: [:comments])
        .map { |step| summary(step.diff) }).to eq(expected_steps)
    end

    it 'compares a version with the current graph' do
      article = create_history
      expected = { title: 'v4', added: [], removed: ['first edited'], changed: [] }

      diff = PaperTrailDiff.compare(article.versions[2], article, associations: [:comments])
      expect(summary(diff)).to eq(expected)
      expect(summary(PaperTrailDiff.compare_many(
        [{ from: article.versions[2], to: article }], associations: [:comments]
      ).values.first)).to eq(expected)
    end
  end

  def tied_version(table, id)
    version_class = Struct.new(:id, :created_at, :item_type, :item_id) do
      define_singleton_method(:table_name) { table }
    end
    version_class.new(id, Time.utc(2026, 1, 1), 'TrackedArticle', 1)
  end

  # Each version table counts its own ids, so ids from two tables say nothing
  # about which version came first.
  it 'refuses a tie between version tables, even with sequential ids' do
    versions = tied_version('versions', 7)
    comments = tied_version('comments', 3)

    expect(PaperTrailDiff::Support.ambiguous_pair([versions, comments]))
      .to eq([versions, comments])
    expect(PaperTrailDiff::Support.ambiguous_pair([versions, tied_version('versions', 8)]))
      .to be_nil
    expect { PaperTrailDiff::VersionBoundary.at_or_after?(comments, versions) }
      .to raise_error(PaperTrailDiff::AmbiguousVersionOrderError)
  end

  it 'refuses to build activity from events it cannot order' do
    article = TrackedArticle.create!(title: 'Tied')
    tied = [tied_version('versions', 7), tied_version('comments', 3)]
    collector = PaperTrailDiff::ActivityVersionCollector.new(
      article, root_versions: tied, tree: PaperTrailDiff::AssociationTree.build([])
    )

    expect { collector.call }.to raise_error(PaperTrailDiff::AmbiguousVersionOrderError)
  end

  it 'refuses a tie its version ids cannot order' do
    version_class = Struct.new(:id, :created_at, :item_type) do
      def self.table_name = 'uuid_versions'
    end
    instant = Time.utc(2026, 1, 1)
    boundary = version_class.new('7d0c', instant, 'TrackedArticle')
    candidate = version_class.new('a91f', instant, 'TrackedComment')

    expect { PaperTrailDiff::VersionBoundary.at_or_after?(candidate, boundary) }
      .to raise_error(PaperTrailDiff::AmbiguousVersionOrderError)
  end
end
