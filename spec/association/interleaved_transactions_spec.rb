# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :interleaved_articles, force: true do |table|
    table.string :title, null: false
    table.timestamps null: false
  end

  create_table :interleaved_comments, force: true do |table|
    table.integer :article_id, null: false
    table.string :body, null: false
    table.timestamps null: false
  end
end

class InterleavedArticle < ActiveRecord::Base
  has_many :comments, class_name: 'InterleavedComment', foreign_key: :article_id,
                      inverse_of: :article
  has_paper_trail
end

class InterleavedComment < ActiveRecord::Base
  belongs_to :article, class_name: 'InterleavedArticle', inverse_of: :comments
  has_paper_trail
end

# Two transactions saving in one article's tree at the same time interleave
# their versions. Each version is written as the other transaction's changes
# stood when it was saved, uncommitted, so a record the other one saves reads
# as it stood before that one began, until it ends.
RSpec.describe 'Interleaved transactions',
               mutant_expression: 'PaperTrailDiff::ActivitySnapshotSequence' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    InterleavedComment.delete_all
    InterleavedArticle.delete_all
  end

  let(:paths) { [:comments] }

  # Saves the block's versions as part of transaction `id`, as if they were
  # saved while other transactions were open. A test saves them one after
  # another, so the order of the versions is the order of the blocks. The
  # number is one no version of the suite takes as its id.
  def in_transaction(id, whodunnit, &)
    saved = PaperTrail::Version.maximum(:id) || 0
    PaperTrail.request(whodunnit: whodunnit, &)
    PaperTrail::Version.where('id > ?', saved).update_all(transaction_id: 1_000_000 + id)
  end

  # Each reported change row as its kind, comment body or field, and who
  # saved the version it is credited to.
  def rows(article, **options)
    SpecTimelines.activity_timeline(article, associations: paths, **options)
                 .flat_map(&:change_rows).map { |row| describe_row(row) }
  end

  def describe_row(row)
    author = PaperTrail::Version.find(row.source.version_id).whodunnit
    [row.change, row.association_path, row.attribute, [row.from, row.to], author]
  end

  def bodies(snapshot)
    snapshot.associations.fetch('comments').records.map { |record| record.attributes.fetch('body') }
  end

  # Alice creates a comment and deletes it again; Bob renames the article in
  # between.
  def transient_comment
    article = InterleavedArticle.create!(title: 'one')
    article.comments.create!(body: 'kept')
    transient = nil
    in_transaction(100, 'alice') { transient = article.comments.create!(body: 'transient') }
    in_transaction(200, 'bob') { article.update!(title: 'two') }
    in_transaction(100, 'alice') { transient.destroy! }
    in_transaction(300, 'carol') { article.update!(title: 'three') }
    article.reload
  end

  [nil, :transaction].each do |group|
    context "with group: #{group.inspect}" do
      it 'leaves out a comment one transaction created and deleted while another saved' do
        article = transient_comment

        expect(rows(article, group: group).map(&:last)).not_to include('alice')
        expect(rows(article, group: group).select { |row| row.last == 'bob' })
          .to eq([[:changed, [], 'title', %w[one two], 'bob']])
      end

      it 'credits a comment that outlives its transaction to that transaction, once it ends' do
        article = InterleavedArticle.create!(title: 'one')
        kept = article.comments.create!(body: 'kept')
        in_transaction(100, 'alice') { article.comments.create!(body: 'new') }
        in_transaction(200, 'bob') { kept.update!(body: 'edited') }
        in_transaction(100, 'alice') { article.update!(title: 'two') }
        article.reload

        by_author = rows(article, group: group).reject { |row| row.last.nil? }.group_by(&:last)
        expect(by_author.fetch('bob').map { |row| row.first(4) })
          .to eq([[:changed, ['comments'], 'body', %w[kept edited]]])
        expect(by_author.fetch('alice').map { |row| row.first(2) }.uniq)
          .to contain_exactly([:changed, []], [:added, ['comments']])
      end

      it 'leaves out a transient comment when the other transaction saves only comments' do
        article = InterleavedArticle.create!(title: 'one')
        kept = article.comments.create!(body: 'kept')
        transient = nil
        in_transaction(100, 'alice') { transient = article.comments.create!(body: 'transient') }
        in_transaction(200, 'bob') { kept.update!(body: 'edited') }
        in_transaction(100, 'alice') { transient.destroy! }
        in_transaction(300, 'carol') { article.update!(title: 'two') }
        article.reload

        expect(rows(article, group: group).reject { |row| row.last.nil? })
          .to eq([[:changed, ['comments'], 'body', %w[kept edited], 'bob'],
                  [:changed, [], 'title', %w[one two], 'carol']])
      end
    end
  end

  it 'starts a window inside the other transaction without the transient comment' do
    article = transient_comment
    bob = article.versions.find_by!(whodunnit: 'bob')
    analysis = PaperTrailDiff.analyze(article, within: bob.created_at..Time.now.utc,
                                               associations: paths, activity: true)

    expect(bodies(analysis.from_snapshot)).to eq(['kept'])
    expect(analysis.diff.associations['comments']).to be_nil
    expect(analysis.diff.attributes.keys).to eq(['title'])
  end

  it 'reads the same in a batch as alone' do
    article = transient_comment
    other = InterleavedArticle.create!(title: 'other')
    within = article.versions.minimum(:created_at)..Time.now.utc
    batched = PaperTrailDiff.analyze_many([article, other], within: within, activity: true,
                                                            associations: paths)
    timeline = batched.fetch(PaperTrailDiff::Endpoint.identity(article)).activity_timeline

    expect(timeline.flat_map(&:change_rows).map { |row| describe_row(row) })
      .to eq(rows(article, within: within))
  end

  # A version saved outside a transaction, while one was open, reads that
  # transaction as not yet ended, from a comparison as from a range.
  it 'compares from a version saved outside a transaction as the range from it reads' do
    article = InterleavedArticle.create!(title: 'one')
    comment = article.comments.create!(body: 'before')
    in_transaction(100, 'alice') { comment.update!(body: 'after') }
    in_transaction(200, 'bob') { article.update!(title: 'two') }
    article.versions.reorder(:id).last.update_columns(transaction_id: nil)
    in_transaction(100, 'alice') { InterleavedComment.create!(article: article, body: 'late') }
    version = article.versions.reorder(:id).last

    compared = PaperTrailDiff.compare(version, article.reload, associations: paths)
    ranged = PaperTrailDiff.analyze(article, from: version, associations: paths, activity: true)

    changed = compared.associations.fetch('comments').changed
    expect(compared.to_h).to eq(ranged.diff.to_h)
    expect(changed.map { |change| change.attributes['body'].to_h })
      .to eq([{ from: 'before', to: 'after' }])
  end
end
