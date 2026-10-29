# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :selection_pages, force: true do |table|
    table.string :title, null: false
    table.timestamps null: false
  end

  create_table :selection_notes, force: true do |table|
    table.string :body, null: false
    table.references :notable, polymorphic: true
    table.timestamps null: false
  end
end

class SelectionPage < ActiveRecord::Base
  has_many :notes, class_name: 'SelectionNote', as: :notable, inverse_of: :notable
  has_paper_trail
end

class SelectionNote < ActiveRecord::Base
  belongs_to :notable, polymorphic: true, optional: true
  has_paper_trail
end

# With activity, a record is selected when it or a record on a requested path
# changed in the window, because an activity analysis reports both. These
# records have no version of their own in the window.
RSpec.describe PaperTrailDiff::AssociationActivitySelection do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    ActiveRecord::Base.connection.execute('DELETE FROM tracked_articles_tags')
    [TrackedReply, TrackedComment, TrackedAuthorship, TrackedProfile, TrackedArticle,
     TrackedAuthor, TrackedTag, SelectionNote, SelectionPage].each(&:delete_all)
  end

  def ids(result)
    result.analyses.keys.map { |identity| identity.last.to_i }.sort
  end

  def scope_ids(associations, window, **options)
    ids(PaperTrailDiff.analyze_scope(TrackedArticle, within: window, associations: associations,
                                                     activity: true, limit: 10, **options))
  end

  def statements(&block)
    count = 0
    callback = lambda do |*, payload|
      count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    count
  end

  it 'selects an article whose only change was to a comment, and reports that change' do
    article = TrackedArticle.create!(title: 'Quiet')
    TrackedArticle.create!(title: 'Untouched').comments.create!(body: 'still')
    comment = article.comments.create!(body: 'one')
    since = Time.now.utc
    comment.update!(body: 'two')

    report = PaperTrailDiff.report(TrackedArticle, since: since, associations: [:comments],
                                                   limit: 10)

    expect(report.roots).to eq([article])
    change = report.analyses.values.first.diff.associations.fetch('comments').changed.first
    expect(change.attributes.fetch('body').to_h).to eq(from: 'one', to: 'two')
  end

  it 'tells records that changed themselves apart by their timeline' do
    quiet = TrackedArticle.create!(title: 'Quiet')
    edited = TrackedArticle.create!(title: 'Edited')
    comment = quiet.comments.create!(body: 'one')
    since = Time.now.utc
    comment.update!(body: 'two')
    edited.update!(title: 'Edited again')

    report = PaperTrailDiff.report(TrackedArticle, since: since, associations: [:comments],
                                                   limit: 10)
    own = report.analyses.reject { |_identity, analysis| analysis.timeline.empty? }

    expect(ids(report)).to eq([quiet.id, edited.id])
    expect(own.keys).to eq([PaperTrailDiff::Endpoint.identity(edited)])
  end

  it 'selects both articles when a comment moves between them' do
    first = TrackedArticle.create!(title: 'From')
    second = TrackedArticle.create!(title: 'To')
    comment = first.comments.create!(body: 'moving')
    window_start = Time.now.utc
    comment.update!(article: second)

    expect(scope_ids([:comments], window_start..Time.now.utc)).to eq([first.id, second.id])
  end

  it 'keeps selecting by own versions only for checkpoint analyses, which cannot see the rest' do
    article = TrackedArticle.create!(title: 'Quiet')
    comment = article.comments.create!(body: 'one')
    window_start = Time.now.utc
    comment.update!(body: 'two')

    result = PaperTrailDiff.analyze_scope(TrackedArticle, within: window_start..Time.now.utc,
                                                          associations: [:comments], limit: 10)

    expect(result.analyses).to be_empty
  end

  it 'ignores changes outside the window and outside the requested paths' do
    article = TrackedArticle.create!(title: 'Quiet')
    comment = article.comments.create!(body: 'before')
    profile = TrackedProfile.create!(article: article, bio: 'bio')
    comment.update!(body: 'still before')
    window_start = Time.now.utc
    profile.update!(bio: 'changed, but not requested')
    window_end = Time.now.utc
    comment.update!(body: 'after')

    expect(scope_ids([:comments], window_start..window_end)).to be_empty
  end

  it 'selects through a nested path whose middle record did not change' do
    article = TrackedArticle.create!(title: 'Quiet')
    reply = article.comments.create!(body: 'comment').replies.create!(body: 'one')
    TrackedArticle.create!(title: 'Other').comments.create!(body: 'other').replies
                  .create!(body: 'other')
    window_start = Time.now.utc
    reply.update!(body: 'two')

    expect(scope_ids(['comments.replies'], window_start..Time.now.utc)).to eq([article.id])
  end

  it 'selects every article pointing at a renamed author, and only those' do
    author = TrackedAuthor.create!(name: 'Ann')
    articles = Array.new(2) do |index|
      TrackedArticle.create!(title: "By Ann #{index}", author: author)
    end
    TrackedArticle.create!(title: 'By someone else', author: TrackedAuthor.create!(name: 'Bea'))
    window_start = Time.now.utc
    author.update!(name: 'Anne')

    expect(scope_ids([:author], window_start..Time.now.utc)).to eq(articles.map(&:id))
  end

  it 'selects through has_many :through for a renamed source or a removed join row' do
    renamed = TrackedArticle.create!(title: 'Renamed contributor')
    removed = TrackedArticle.create!(title: 'Removed contributor')
    writer = TrackedAuthor.create!(name: 'Wes')
    TrackedAuthorship.create!(article: renamed, author: writer, role: 'writer')
    editor = TrackedAuthor.create!(name: 'Eda')
    authorship = TrackedAuthorship.create!(article: removed, author: editor, role: 'editor')
    window_start = Time.now.utc
    writer.update!(name: 'Wesley')
    authorship.destroy!

    expect(scope_ids([:contributors], window_start..Time.now.utc))
      .to eq([renamed.id, removed.id])
  end

  # Analysis through a polymorphic belongs_to fails in prepared history before
  # this change too, so the selection is read directly here.
  it 'selects notes whose polymorphic target changed, and only those' do
    page = SelectionPage.create!(title: 'Old')
    note = page.notes.create!(body: 'one')
    SelectionPage.create!(title: 'Other').notes.create!(body: 'other')
    SelectionNote.create!(body: 'on an article', notable: TrackedArticle.create!(title: 'A'))
    window_start = Time.now.utc
    page.update!(title: 'New')

    sources = described_class.new(
      SelectionNote, tree: PaperTrailDiff::AssociationTree.build([:notable]),
                     time_range: PaperTrailDiff::TimeRange.new(window_start..Time.now.utc)
    ).call
    selected = sources.flat_map { |ids| ids.is_a?(described_class::Query) ? ids.values : ids }

    expect(selected.map(&:to_i).uniq).to eq([note.id])
  end

  it 'selects a page whose note changed although the page did not' do
    page = SelectionPage.create!(title: 'Quiet')
    note = page.notes.create!(body: 'one')
    SelectionPage.create!(title: 'Other').notes.create!(body: 'other')
    since = Time.now.utc
    note.update!(body: 'two')

    report = PaperTrailDiff.report(SelectionPage, since: since, associations: [:notes], limit: 10)

    expect(report.roots).to eq([page])
  end

  it 'selects an article whose tag was renamed in a window a later version closes' do
    article = TrackedArticle.create!(title: 'Tagged')
    tag = TrackedTag.create!(name: 'ruby')
    TrackedArticle.transaction do
      article.tags << tag
      article.paper_trail.save_with_version
    end
    TrackedArticle.create!(title: 'Untagged')
    window_start = Time.now.utc
    tag.update!(name: 'rails')
    window_end = Time.now.utc
    TrackedArticle.transaction { TrackedArticle.find(article.id).paper_trail.save_with_version }

    expect(scope_ids([:tags], window_start..window_end)).to eq([article.id])
  end

  # HABTM membership after the article's last version lives only in the join
  # table, and a window ending at the current record cannot split HABTM
  # activity into events. The article is still selected, so that says so.
  it 'raises rather than omit an article whose tag changed after its last version' do
    article = TrackedArticle.create!(title: 'Tagged')
    tag = TrackedTag.create!(name: 'ruby')
    TrackedArticle.transaction do
      article.tags << tag
      article.paper_trail.save_with_version
    end
    window_start = Time.now.utc
    tag.update!(name: 'rails')

    expect { scope_ids([:tags], window_start..Time.now.utc) }
      .to raise_error(PaperTrailDiff::UnsupportedLiveActivityError, /tags/)
  end

  it 'applies the relation, historical_filter:, and limit: to the records it adds' do
    kept = TrackedArticle.create!(title: 'Kept')
    dropped = TrackedArticle.create!(title: 'Dropped')
    comments = [kept, dropped].map { |article| article.comments.create!(body: 'one') }
    window_start = Time.now.utc
    comments.each { |comment| comment.update!(body: 'two') }
    window = window_start..Time.now.utc

    filtered = PaperTrailDiff.analyze_scope(
      TrackedArticle.where(title: 'Kept'), within: window, associations: [:comments],
                                           activity: true, limit: 10
    )
    historical = scope_ids([:comments], window, historical_filter: { 'title' => 'Dropped' })

    expect(ids(filtered)).to eq([kept.id])
    expect(historical).to eq([dropped.id])
    expect do
      PaperTrailDiff.report(TrackedArticle, since: window_start, associations: [:comments],
                                            limit: 1)
    end.to raise_error(PaperTrailDiff::BatchLimitExceededError)
  end

  it 'names an article deleted since as unreachable, and analyzes it when asked' do
    article = TrackedArticle.create!(title: 'Gone')
    comment = article.comments.create!(body: 'one')
    window_start = Time.now.utc
    comment.update!(body: 'two')
    window = window_start..Time.now.utc
    comment.destroy!
    article.destroy!

    result = PaperTrailDiff.analyze_scope(TrackedArticle, within: window, associations: [:comments],
                                                          activity: true, limit: 10,
                                                          include_deleted: true)

    identity = ['TrackedArticle', article.id.to_s]
    expect(result.analyses).to be_empty
    expect(result.unreachable).to eq([identity])
    change = result.deleted.fetch(identity).diff.associations.fetch('comments').changed.first
    expect(change.attributes.fetch('body').to_h).to eq(from: 'one', to: 'two')
  end

  it 'does not fail on a comment left behind by an article deleted before the window' do
    article = TrackedArticle.create!(title: 'Gone early')
    comment = article.comments.create!(body: 'one')
    article.destroy!
    window_start = Time.now.utc
    comment.update!(body: 'two')

    result = PaperTrailDiff.analyze_scope(TrackedArticle, within: window_start..Time.now.utc,
                                                          associations: [:comments],
                                                          activity: true, limit: 10,
                                                          include_deleted: true)

    identity = ['TrackedArticle', article.id.to_s]
    expect(result.unreachable).to eq([identity])
    expect(result.deleted.fetch(identity).activity_timeline).to eq([])
  end

  it 'selects with the same number of queries for one article as for many' do
    measure = lambda do |count|
      PaperTrail::Version.delete_all
      PaperTrail::VersionAssociation.delete_all
      comments = Array.new(count) do |index|
        TrackedArticle.create!(title: "Article #{index}").comments.create!(body: 'one')
      end
      since = Time.now.utc
      comments.each { |comment| comment.update!(body: 'two') }
      statements do
        PaperTrailDiff::ScopedRootSelection.new(
          TrackedArticle, time_range: PaperTrailDiff::TimeRange.new(since..Time.now.utc),
                          limit: 100,
                          activity_tree: PaperTrailDiff::AssociationTree.build(['comments.replies',
                                                                                'author'])
        ).call
      end
    end

    expect(measure.call(1)).to eq(measure.call(12))
  end
end
