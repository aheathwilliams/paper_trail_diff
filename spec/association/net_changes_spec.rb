# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/documentation_examples'

# Net changes over real histories, whose rows name their own records'
# versions and, with recorded changes read, split off what no version
# recorded. The fold itself is checked in spec/unit/net_changes_spec.rb.
RSpec.describe 'Net changes',
               mutant_expression: %w[PaperTrailDiff::NetChanges PaperTrailDiff::NetChange] do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedReply, TrackedComment, TrackedArticle, TrackedAuthor].each(&:delete_all)
  end

  let(:options) do
    { associations: [:comments], activity: true, snapshots: true, recorded_changes: true }
  end

  # Each change as its record's id, whether it was added or removed, and the
  # fields that differ, leaving out the timestamps.
  def table(changes)
    changes.map do |change|
      fields = change.diff.attributes.except('created_at', 'updated_at')
      [change.record&.id, change.added?, change.removed?,
       fields.transform_values { |value| [value.from, value.to] }]
    end
  end

  def authored(analysis)
    analysis.net_changes { |row| row.source.whodunnit }
  end

  describe 'what people changed' do
    # Alice edits the article and a comment in one save, then the system
    # rewrites both without a version; Bob adds a comment, which the system
    # rewrites too, and deletes one.
    let!(:history) do
      article = kept = gone = nil
      PaperTrail.request(whodunnit: 'setup') do
        article = TrackedArticle.create!(title: 'A')
        kept = article.comments.create!(body: 'one')
        gone = article.comments.create!(body: 'gone')
      end
      start = Time.now.utc
      PaperTrail.request(whodunnit: 'alice') do
        TrackedArticle.transaction do
          article.update!(title: 'B')
          kept.update!(body: 'two')
        end
      end
      article.update_columns(title: 'Z')
      kept.update_columns(body: 'drift')
      added = PaperTrail.request(whodunnit: 'bob') { article.comments.create!(body: 'new') }
      added.update_columns(body: 'rewritten')
      PaperTrail.request(whodunnit: 'bob') { gone.destroy! }
      { article: article, kept: kept, gone: gone, added: added, start: start }
    end

    def analysis(**extra)
      PaperTrailDiff.analyze(history.fetch(:article), within: history.fetch(:start)..,
                                                      **options, **extra)
    end

    it 'leaves out the writes saved without a version, grouped or not' do
      kept, gone, added = history.values_at(:kept, :gone, :added)

      [{}, { group: :transaction }].each do |grouping|
        changes = authored(analysis(**grouping))

        expect(table(changes)).to eq([[nil, false, false, { 'title' => %w[A B] }],
                                      [kept.id, false, false, { 'body' => %w[one two] }],
                                      [added.id, true, false, {}],
                                      [gone.id, false, true, {}]])
        expect(changes.first.after.attributes['title']).to eq('B')
        expect(changes[2].after.attributes['body']).to eq('new')
        expect(changes.map { |change| change.sources.map(&:whodunnit).uniq })
          .to eq([['alice'], ['alice'], ['bob'], ['bob']])
      end
    end

    it 'keeps them without a block' do
      changes = analysis.net_changes

      expect(table(changes).first(2)).to eq([[nil, false, false, { 'title' => %w[A Z] }],
                                             [history.fetch(:kept).id, false, false,
                                              { 'body' => %w[one drift] }]])
      expect(changes.first.sources.map(&:kind)).to eq(%i[version unversioned])
    end
  end

  it 'reads from the whole history before the first change a version filter keeps' do
    article = TrackedArticle.create!(title: 'A')
    start = Time.now.utc
    PaperTrail.request(whodunnit: 'bob') { article.update!(title: 'B') }
    PaperTrail.request(whodunnit: 'alice') { article.update!(title: 'C') }
    alice = ->(versions) { versions.where(whodunnit: 'alice') }

    analysis = PaperTrailDiff.analyze(article, within: start.., version_scope: alice, **options)

    expect(table(analysis.net_changes)).to eq([[nil, false, false, { 'title' => %w[B C] }]])
  end

  it 'reads the same from a report, keyed as its change rows are, deleted records last' do
    deleted = TrackedArticle.create!(title: 'D')
    edited = TrackedArticle.create!(title: 'A')
    start = Time.now.utc
    PaperTrail.request(whodunnit: 'bob') { deleted.destroy! }
    PaperTrail.request(whodunnit: 'alice') { edited.update!(title: 'B') }
    edited.update_columns(title: 'Z')

    options = self.options.except(:activity).merge(include_deleted: true)
    report = PaperTrailDiff.report(TrackedArticle.all, since: start, limit: 5, **options)
    changes = report.net_changes { |row| row.source.whodunnit }

    expect(changes.keys).to eq(report.change_rows.keys)
    expect(changes.transform_values { |list| table(list) })
      .to eq(['TrackedArticle', edited.id.to_s] => [[nil, false, false, { 'title' => %w[A B] }]],
             ['TrackedArticle', deleted.id.to_s] => [[nil, false, true, {}]])
  end

  describe 'the documented examples' do
    # Alice retitles the article, the system rewrites it without a version,
    # and Bob adds a comment.
    let!(:article) do
      article = PaperTrail.request(whodunnit: 'alice') { TrackedArticle.create!(title: 'Draft') }
      PaperTrail.request(whodunnit: 'alice') { article.update!(title: 'Published') }
      article.update_columns(title: 'Rewritten')
      PaperTrail.request(whodunnit: 'bob') { article.comments.create!(body: 'First') }
      article
    end
    let(:expected) do
      [[nil, true, false, {}], [article.comments.first.id, true, false, {}]]
    end

    def evaluate(file, session, **locals)
      context = Object.new.instance_eval { binding }
      locals.each { |name, value| context.local_variable_set(name, value) }
      DocumentationExamples.evaluate(File.expand_path("../../#{file}", __dir__),
                                     session: session, context: context)
      context.local_variable_get(:changes)
    end

    it "runs the README's report example" do
      stub_const('Article', TrackedArticle)
      changes = evaluate('README.md', 'recipe-net-changes')

      expect(changes.transform_values { |list| table(list) })
        .to eq(['TrackedArticle', article.id.to_s] => expected)
      expect(changes.values.first.first.after.attributes['title']).to eq('Published')
    end

    it "runs the reference's example" do
      changes = evaluate('docs/reference.md', 'reference-net-changes', article: article)

      expect(table(changes)).to eq(expected)
      expect(changes.first.after.attributes['title']).to eq('Published')
    end
  end

  it 'needs the activity timeline and its snapshots' do
    article = TrackedArticle.create!(title: 'A')
    article.update!(title: 'B')

    expect { PaperTrailDiff.analyze(article).net_changes }
      .to raise_error(PaperTrailDiff::ConfigurationError, 'net_changes requires activity: true')
    [{}, { group: :transaction }].each do |grouping|
      analysis = PaperTrailDiff.analyze(article, activity: true, **grouping)

      expect { analysis.net_changes }
        .to raise_error(PaperTrailDiff::ConfigurationError, 'net_changes requires snapshots: true')
    end
  end
end
