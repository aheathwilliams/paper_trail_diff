# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :overlap_articles, force: true do |table|
    table.string :title, null: false
    table.timestamps null: false
  end

  create_table :overlap_comments, force: true do |table|
    table.integer :article_id, null: false
    table.string :body, null: false
    table.timestamps null: false
  end
end

class OverlapArticle < ActiveRecord::Base
  has_many :comments, class_name: 'OverlapComment', foreign_key: :article_id, inverse_of: :article
  has_paper_trail
end

class OverlapComment < ActiveRecord::Base
  belongs_to :article, class_name: 'OverlapArticle', inverse_of: :comments
  has_paper_trail
end

# A transaction takes effect where it saved its last version in the tree: its
# changes are reported there, under its own versions, and a window holds it
# when it holds that version. Two transactions that save in one tree at the
# same time interleave their versions, and a window's edge can fall between
# two versions of one transaction.
RSpec.describe 'Transactions that overlap each other or a window edge',
               mutant_expression: 'PaperTrailDiff::TransactionEnds' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    OverlapComment.delete_all
    OverlapArticle.delete_all
  end

  let(:paths) { [:comments] }

  # Saves the block's versions as part of transaction `id`, as if they were
  # saved while other transactions were open, under a number no version of
  # the suite takes as its id. Returns the last of them.
  def in_transaction(id, whodunnit, &)
    saved = PaperTrail::Version.maximum(:id) || 0
    PaperTrail.request(whodunnit: whodunnit, &)
    versions = PaperTrail::Version.where('id > ?', saved)
    versions.update_all(transaction_id: 1_000_000 + id)
    versions.order(:id).last
  end

  # Each reported change of a comment or of the title: its kind, the field,
  # its values and who saved the version it is credited to.
  def rows(article, **options)
    PaperTrailDiff.activity_timeline(article, associations: paths, **options)
                  .flat_map(&:change_rows).filter_map { |row| describe_row(row) }
  end

  def describe_row(row)
    return unless [nil, 'body', 'title'].include?(row.attribute)

    version = PaperTrail::Version.find_by(id: row.source.version_id)
    [row.change, row.association_path, row.attribute, [row.from, row.to], version&.whodunnit]
  end

  # The window from one version up to another, which it leaves out.
  def between(first, last)
    first.created_at...last.created_at
  end

  # A window that starts at a version and has no end.
  def from(version)
    version.created_at..
  end

  # Alice deletes a comment, creates another and deletes it again; Bob adds
  # a comment in between.
  def removal_around_a_transient_comment
    article = OverlapArticle.create!(title: 'one')
    kept = article.comments.create!(body: 'kept')
    scratch = nil
    versions = [
      in_transaction(100, 'alice') { kept.destroy! },
      in_transaction(100, 'alice') { scratch = article.comments.create!(body: 'scratch') },
      in_transaction(200, 'bob') { article.comments.create!(body: 'bobs') },
      in_transaction(100, 'alice') { scratch.destroy! }
    ]
    [article.reload, versions]
  end

  [nil, :transaction].each do |group|
    context "with group: #{group.inspect}" do
      it 'credits a removal to the transaction that made it, not to one saved meanwhile' do
        article, = removal_around_a_transient_comment

        removed = rows(article, group: group).select { |row| row.first == :removed }
        expect(removed).to eq([[:removed, ['comments'], nil, [nil, nil], 'alice'],
                               [:removed, ['comments'], 'body', ['kept', nil], 'alice']])
      end

      it 'reports each change in one of the windows that meet inside overlapping transactions' do
        article, versions = removal_around_a_transient_comment
        whole = rows(article, group: group, within: from(versions.first))
        windows = [*versions.each_cons(2).map { |pair| between(*pair) }, from(versions.last)]

        parts = windows.flat_map { |window| rows(article, group: group, within: window) }
        expect(parts).to match_array(whole)
        expect(whole.map(&:first).tally).to eq(removed: 2, added: 2)
      end

      it 'reports a change once when a transaction saves a comment, then the article, ' \
         'around another transaction' do
        article = OverlapArticle.create!(title: 'one')
        kept = article.comments.create!(body: 'kept')
        versions = [
          in_transaction(100, 'tess') { kept.update!(body: 'edited') },
          in_transaction(200, 'uma') { article.update!(title: 'two') },
          in_transaction(100, 'tess') { article.update!(title: 'three') }
        ]
        article.reload
        whole = rows(article, group: group, within: from(versions.first))
        windows = [*versions.each_cons(2).map { |pair| between(*pair) }, from(versions.last)]

        parts = windows.flat_map { |window| rows(article, group: group, within: window) }
        expect(parts).to match_array(whole)
        expect(whole).to contain_exactly(
          [:changed, [], 'title', %w[one two], 'uma'],
          [:changed, [], 'title', %w[two three], 'tess'],
          [:changed, ['comments'], 'body', %w[kept edited], 'tess']
        )
      end
    end
  end

  # Alice deletes a comment, then saves one that was moved to another article
  # before she began, which no window from then on holds. Her transaction
  # ends there all the same, for every window.
  it 'reports a transaction that goes on to save a record outside the tree once, where it ends' do
    article = OverlapArticle.create!(title: 'one')
    kept = article.comments.create!(body: 'kept')
    moved = article.comments.create!(body: 'moved')
    moved.update!(article: OverlapArticle.create!(title: 'other'))
    removal = in_transaction(100, 'alice') { kept.destroy! }
    outside = in_transaction(100, 'alice') { moved.update!(body: 'elsewhere') }
    article.reload
    removed = [[:removed, ['comments'], nil, [nil, nil], 'alice'],
               [:removed, ['comments'], 'body', ['kept', nil], 'alice']]

    expect(rows(article, within: between(removal, outside))).to eq([])
    expect(rows(article, within: from(outside))).to eq(removed)
    expect(rows(article, within: from(removal))).to eq(removed)
  end

  # The window holds no version of the article or of its comments, only the
  # last version of a transaction that removed one of them before it.
  it 'selects a record for a window by a transaction that saved its tree only before it' do
    article = OverlapArticle.create!(title: 'one')
    kept = article.comments.create!(body: 'kept')
    moved = article.comments.create!(body: 'moved')
    moved.update!(article: OverlapArticle.create!(title: 'other'))
    in_transaction(100, 'alice') { kept.destroy! }
    outside = in_transaction(100, 'alice') { moved.update!(body: 'elsewhere') }

    scoped = PaperTrailDiff.analyze_scope(
      OverlapArticle.where(id: article.id), limit: 5, within: from(outside),
                                            associations: paths, activity: true
    )

    rows = scoped.analysis_for(article).activity_timeline.flat_map(&:change_rows)
    expect(rows.map { |row| [row.change, row.attribute, row.from] })
      .to include([:removed, 'body', 'kept'])
  end

  it 'credits a change to its own version in a window that starts inside its transaction' do
    article = OverlapArticle.create!(title: 'one')
    first = article.comments.create!(body: 'first')
    edit = in_transaction(100, 'alice') { first.update!(body: 'edited') }
    create = in_transaction(100, 'alice') { article.comments.create!(body: 'second') }
    article.reload

    changed = PaperTrailDiff.activity_timeline(article, associations: paths, within: from(create))
                            .flat_map(&:change_rows).select { |row| row.attribute == 'body' }
    expect(changed.map { |row| [row.change, row.to, row.source.version_id] })
      .to contain_exactly([:changed, 'edited', edit.id], [:added, 'second', create.id])
  end
end
