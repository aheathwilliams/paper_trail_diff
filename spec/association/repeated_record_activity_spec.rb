# frozen_string_literal: true

require_relative '../support/association_database'

# A path can lead to one record twice: an article's author's articles include
# the article. An event on it changes every place it sits at.
RSpec.describe 'Activity for a record at two places in the tree',
               mutant_expression: 'PaperTrailDiff::ActivityTimelineBuilder' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedComment, TrackedArticle, TrackedAuthor].each(&:delete_all)
  end

  def as(name, &block)
    PaperTrail.request(whodunnit: name, &block)
  end

  def steps(root, path, **options)
    SpecTimelines.activity_timeline(root, associations: [path], snapshots: true, **options)
  end

  def step_by(steps, name)
    steps.find { |step| step.source_boundary.whodunnit == name }
  end

  def credited(root, path, value)
    analysis = PaperTrailDiff.analyze(root, associations: [path], activity: true)
    rows = analysis.change_rows.select { |row| row.change == :changed && row.to == value }
    rows.map { |row| [row.association_path, row.source.whodunnit] }
  end

  context 'when the root is reached again below itself' do
    let(:author) { TrackedAuthor.create!(name: 'Ann') }
    let(:article) { TrackedArticle.create!(title: 'Draft', author: author) }
    let(:other) { TrackedArticle.create!(title: 'Other', author: author) }

    def listed(snapshot, record)
      articles = snapshot.associations.fetch('author').records.first.associations.fetch('articles')
      articles.records.find { |entry| entry.id == record.id }
    end

    before do
      [article, other]
      as('alice') { article.update!(title: 'Published') }
      as('bob') { other.update!(title: 'Other, edited') }
    end

    it 'changes both places in the step of the root event' do
      step = step_by(steps(article, 'author.articles'), 'alice')

      expect(step.to_snapshot.attributes.fetch('title')).to eq('Published')
      expect(listed(step.to_snapshot, article).attributes.fetch('title')).to eq('Published')
      expect(step.diff.associations).to have_key('author')
    end

    it 'leaves the next step with its own change only' do
      step = step_by(steps(article, 'author.articles'), 'bob')
      changed = step.diff.associations.fetch('author').changed.associations.fetch('articles')

      expect(changed.changed.map { |change| change.record.id }).to eq([other.id])
    end

    it 'credits each place to the version that changed it' do
      expect(credited(article, 'author.articles', 'Published'))
        .to contain_exactly([[], 'alice'], [%w[author articles], 'alice'])
    end

    it 'reports both places in a window around the root event alone' do
      version = article.versions.reorder(:id).last
      window = (version.created_at - 0.000_001)..version.created_at

      analysis = PaperTrailDiff.analyze(article, within: window, activity: true,
                                                 associations: ['author.articles'])

      expect(analysis.diff.attributes.keys).to eq(['title'])
      expect(analysis.diff.associations).to have_key('author')
    end

    it 'changes both places when the root event shares its transaction' do
      as('carol') do
        TrackedArticle.transaction do
          other.update!(title: 'Third')
          article.update!(title: 'Final')
        end
      end

      step = steps(article, 'author.articles', group: :transaction).last

      expect(listed(step.to_snapshot, article).attributes.fetch('title')).to eq('Final')
      expect(listed(step.to_snapshot, other).attributes.fetch('title')).to eq('Third')
    end
  end

  context 'when a record is a member of a collection and the target of a belongs_to below it' do
    let(:author) { TrackedAuthor.create!(name: 'Ann') }
    let(:article) { TrackedArticle.create!(title: 'Draft', author: author) }
    let(:comment) { TrackedComment.create!(body: 'First', article: article) }

    def nested(snapshot)
      member = snapshot.associations.fetch('articles').records.first
      [member, member.associations.fetch('comments').records.first
                     .associations.fetch('article').records.first]
    end

    before do
      comment
      as('alice') { article.update!(title: 'Published') }
      as('bob') { comment.update!(body: 'Second') }
    end

    it 'changes both places in the step of its event' do
      step = step_by(steps(author, 'articles.comments.article'), 'alice')

      expect(nested(step.to_snapshot).map { |entry| entry.attributes.fetch('title') })
        .to eq(%w[Published Published])
    end

    it 'credits both places to its version' do
      expect(credited(author, 'articles.comments.article', 'Published'))
        .to contain_exactly([%w[articles], 'alice'], [%w[articles comments article], 'alice'])
    end
  end

  context 'when the root is one of the records its parent holds' do
    let(:article) { TrackedArticle.create!(title: 'Draft') }
    let(:comment) { TrackedComment.create!(body: 'First', article: article) }
    let(:sibling) { TrackedComment.create!(body: 'Sibling', article: article) }

    before do
      [comment, sibling]
      as('alice') { comment.update!(body: 'Second') }
      as('bob') { sibling.update!(body: 'Sibling, edited') }
    end

    it 'changes the root among its siblings in the step of the root event' do
      step = step_by(steps(comment, 'article.comments'), 'alice')
      siblings = step.to_snapshot.associations.fetch('article').records.first
                     .associations.fetch('comments').records

      expect(siblings.to_h { |entry| [entry.id, entry.attributes.fetch('body')] })
        .to eq(comment.id => 'Second', sibling.id => 'Sibling')
    end
  end
end
