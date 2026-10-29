# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/string_item_database'

ActiveRecord::Schema.define do
  create_table :selection_pages, force: true do |table|
    table.string :title, null: false
    table.timestamps null: false
  end

  create_table :selection_notes, force: true do |table|
    table.string :type
    table.string :body, null: false
    table.references :notable, polymorphic: true
    table.integer :author_id
    table.timestamps null: false
  end
end

class SelectionPage < ActiveRecord::Base
  has_many :notes, class_name: 'SelectionNote', as: :notable, inverse_of: :notable
  has_many :pinned_notes, class_name: 'SelectionPinnedNote', as: :notable
  has_paper_trail
end

class SelectionNote < ActiveRecord::Base
  belongs_to :notable, polymorphic: true, optional: true
  belongs_to :author, class_name: 'TrackedAuthor', optional: true
  has_paper_trail
end

class SelectionPinnedNote < SelectionNote
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
     TrackedAuthor, TrackedTag, SelectionNote, SelectionPage,
     UnversionedAttachment].each(&:delete_all)
    StringItemVersionAssociation.delete_all
    StringItemVersion.delete_all
    [StringItemNote, StringItemPost].each(&:delete_all)
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

  # The article shares an id with the renamed page, so only the type keeps its
  # note out. polymorphic_belongs_to_spec.rb covers the report itself.
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

  # Only the tag changes in the window. The article's next version, after the
  # window, records that it held the tag; the join row is gone by selection.
  it 'selects an article that held a renamed tag in the window but no longer does' do
    article = TrackedArticle.create!(title: 'Was tagged')
    tag = TrackedTag.create!(name: 'ruby')
    article.tags << tag
    window_start = Time.now.utc
    tag.update!(name: 'rails')
    window_end = Time.now.utc
    TrackedArticle.transaction { TrackedArticle.find(article.id).paper_trail.save_with_version }
    article.tags.delete(tag)

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

  describe 'its sources' do
    def sources(model, paths, window: nil)
      range = PaperTrailDiff::TimeRange.new(window) if window
      described_class.new(model, tree: PaperTrailDiff::AssociationTree.build(paths),
                                 time_range: range).call
    end

    def selected(found)
      described_class.values(found).map(&:to_i).sort
    end

    def since(start)
      start..Time.now.utc
    end

    it 'keeps a subquery typed like the owner column where the columns compared match' do
      article = TrackedArticle.create!(title: 'Quiet')
      comment = article.comments.create!(body: 'one')
      start = Time.now.utc
      comment.update!(body: 'two')

      found = sources(TrackedArticle, [:comments], window: since(start))

      expect(found.map(&:class)).to eq([described_class::Query])
      expect(found.first.type).to eq(:integer)
      expect(selected(found)).to eq([article.id])
    end

    it 'reads ids, in slices, where a string item_id meets an integer key' do
      posts = Array.new(2) { |index| StringItemPost.create!(title: "Post #{index}") }
      note = posts.first.notes.create!(body: 'moving')
      StringItemPost.create!(title: 'Other').notes.create!(body: 'other')
      start = Time.now.utc
      note.update!(post: posts.last)
      posts.each { |post| post.update!(title: 'Renamed') }
      window = since(start)
      count = lambda do |slice|
        stub_const('PaperTrailDiff::AssociationActivitySelection::SLICE', slice)
        found = nil
        [statements { found = sources(StringItemNote, [:post], window: window) }, found]
      end

      whole, found = count.call(2)
      sliced, sliced_found = count.call(1)

      expect(found).to eq([[note.id.to_s]])
      expect(sliced_found).to eq([[note.id.to_s]])
      expect(sliced).to eq(whole + 1)
      expect(sources(StringItemNote, [:post], window: since(Time.now.utc))).to eq([])
    end

    it 'follows read ids back up a child edge, leaving out keys recorded as empty' do
      post = StringItemPost.create!(title: 'Old')
      note = post.notes.create!(body: 'one')
      start = Time.now.utc
      post.update!(title: 'New')
      note.update!(body: 'two')
      StringItemVersionAssociation.joins(:version)
                                  .where(string_item_versions: { item_id: note.id.to_s,
                                                                 event: 'update' })
                                  .update_all(foreign_key_id: nil)

      found = sources(StringItemPost, ['notes.post'], window: since(start))

      expect(found.grep(Array)).to eq([[post.id]])
      expect(found.grep(described_class::Query).map(&:type)).to eq([:integer])
      expect(described_class.values(found)).to eq([post.id])
    end

    it 'reads owners only from the window and the state when it opened' do
      before = TrackedArticle.create!(title: 'Held it before')
      after = TrackedArticle.create!(title: 'Holds it')
      comment = before.comments.create!(body: 'one')
      comment.update!(article: after)
      start = Time.now.utc
      comment.update!(body: 'two')

      expect(selected(sources(TrackedArticle, [:comments], window: since(start))))
        .to eq([after.id])
      expect(selected(sources(TrackedArticle, [:comments]))).to eq([before.id, after.id])
    end

    it 'reads a change of a model of the path only, not another with the same id' do
      article = TrackedArticle.create!(title: 'Quiet')
      comment = article.comments.create!(id: 9_100, body: 'unchanged')
      profile = TrackedProfile.create!(id: comment.id, article: TrackedArticle.create!(title: 'P'),
                                       bio: 'one')
      start = Time.now.utc
      profile.update!(bio: 'two')

      expect(selected(sources(TrackedArticle, [:comments], window: since(start)))).to eq([])
    end

    it 'reads changes of a subclass under the base class name' do
      page = SelectionPage.create!(title: 'Pinned')
      note = SelectionPinnedNote.create!(body: 'one', notable: page)
      start = Time.now.utc
      note.update!(body: 'two')

      expect(selected(sources(SelectionPage, [:pinned_notes], window: since(start))))
        .to eq([page.id])
    end

    it 'reads nothing for a path to an unversioned model' do
      article = TrackedArticle.create!(title: 'Article')
      UnversionedAttachment.create!(article: article, filename: 'a.txt')

      expect(sources(TrackedArticle, [:unversioned_attachments])).to eq([])
    end

    it 'names a nested path it cannot resolve in full' do
      expect { sources(TrackedArticle, ['comments.nope']) }
        .to raise_error(PaperTrailDiff::UnknownAssociationError,
                        'unknown association: comments.nope')
    end

    it 'skips the recorded HABTM edge without a transaction_id column' do
      article = TrackedArticle.create!(title: 'Tagged')
      tag = TrackedTag.create!(name: 'ruby')
      article.tags << tag
      start = Time.now.utc
      tag.update!(name: 'rails')
      allow(PaperTrail::Version).to receive(:column_names)
        .and_return(PaperTrail::Version.column_names - ['transaction_id'])
      sql = []
      callback = ->(*, payload) { sql << payload[:sql] }
      found = nil

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        found = selected(sources(TrackedArticle, [:tags], window: since(start)))
      end

      expect(found).to eq([article.id])
      expect(sql.grep(/transaction_id/)).to eq([])
    end

    describe 'a polymorphic belongs_to' do
      it 'reads each target type it names, and only targets of that type' do
        page = SelectionPage.create!(id: 7_000, title: 'Page')
        article = TrackedArticle.create!(id: 7_000, title: 'Article')
        on_page = page.notes.create!(body: 'on page')
        SelectionNote.create!(body: 'on article', notable: article)
        start = Time.now.utc
        page.update!(title: 'Renamed')

        expect(selected(sources(SelectionNote, [:notable], window: since(start))))
          .to eq([on_page.id])
      end

      it 'reads only the types and owners of the window and its opening state' do
        article = TrackedArticle.create!(title: 'Earlier')
        page = SelectionPage.create!(title: 'Now')
        note = SelectionNote.create!(body: 'moved', notable: article)
        note.update!(notable: page)
        start = Time.now.utc
        article.update!(title: 'Renamed')

        found = sources(SelectionNote, [:notable], window: since(start))

        expect(found.length).to eq(1)
        expect(selected(found)).to eq([])
        expect(selected(sources(SelectionNote, [:notable]))).to eq([note.id])
      end

      it 'reads the owners of a type in the window only from the window' do
        earlier = TrackedArticle.create!(title: 'Earlier')
        later = TrackedArticle.create!(title: 'Later')
        note = SelectionNote.create!(body: 'moved', notable: earlier)
        note.update!(notable: SelectionPage.create!(title: 'Page'))
        start = Time.now.utc
        SelectionNote.create!(body: 'new', notable: later)
        earlier.update!(title: 'Renamed')

        expect(selected(sources(SelectionNote, [:notable], window: since(start)))).to eq([])
      end

      it 'skips a type naming no class or an unversioned one' do
        missing = SelectionNote.create!(body: 'missing',
                                        notable: TrackedArticle.create!(title: 'A'))
        unversioned = SelectionNote.create!(body: 'unversioned',
                                            notable: TrackedArticle.create!(title: 'B'))
        page = SelectionPage.create!(title: 'Page')
        kept = page.notes.create!(body: 'kept')
        {
          missing => 'NoSuchSelectionModel', unversioned => 'UnversionedAttachment'
        }.each do |note, type|
          PaperTrail::VersionAssociation.joins(:version)
                                        .where(versions: { item_type: 'SelectionNote',
                                                           item_id: note.id })
                                        .update_all(foreign_type: type)
        end
        start = Time.now.utc
        page.update!(title: 'Renamed')

        expect(selected(sources(SelectionNote, [:notable], window: since(start))))
          .to eq([kept.id])
      end

      it 'goes on to the paths after it' do
        author = TrackedAuthor.create!(name: 'Ann')
        note = SelectionNote.create!(body: 'one', notable: SelectionPage.create!(title: 'P'),
                                     author: author)
        start = Time.now.utc
        author.update!(name: 'Anne')

        expect(selected(sources(SelectionNote, %i[notable author], window: since(start))))
          .to eq([note.id])
      end
    end
  end

  describe described_class::Query do
    def query(relation = PaperTrail::Version.where(item_type: 'TrackedComment'))
      described_class.new(relation, PaperTrail::Version.arel_table[:item_id], :integer)
    end

    it 'selects its column, keeps its type, and is frozen' do
      selection = query

      expect(selection.type).to eq(:integer)
      expect(selection.relation.select_values).to eq([PaperTrail::Version.arel_table[:item_id]])
      expect(selection).to be_frozen
    end

    it 'reads each id once, leaving out empty keys' do
      article = TrackedArticle.create!(title: 'Article')
      comment = article.comments.create!(body: 'one')
      comment.update!(body: 'two')
      rows = PaperTrail::VersionAssociation.where(foreign_key_name: 'article_id')
      rows.limit(1).update_all(foreign_key_id: nil)
      keys = described_class.new(rows, PaperTrail::VersionAssociation.arel_table[:foreign_key_id],
                                 :integer)

      expect(query.values).to eq([comment.id])
      expect(keys.values).to eq([article.id])
    end

    it 'names each id without a row once' do
      article = TrackedArticle.create!(title: 'Article')
      kept = article.comments.create!(body: 'kept')
      gone = article.comments.create!(body: 'gone')
      gone.update!(body: 'edited')
      TrackedComment.where(id: gone.id).delete_all

      expect(query.missing(TrackedComment.select(:id).arel)).to eq([gone.id])
      expect(kept.id).not_to eq(gone.id)
    end
  end

  it 'reads every id its sources name, once' do
    article = TrackedArticle.create!(title: 'Article')
    article.comments.create!(body: 'one')
    sources = [
      described_class::Query.new(PaperTrail::Version.where(item_type: 'TrackedComment'),
                                 PaperTrail::Version.arel_table[:item_id], :integer),
      [41, 42], [42]
    ]

    narrowed = Class.new(described_class::Query).new(
      PaperTrail::Version.where(item_type: 'TrackedArticle'),
      PaperTrail::Version.arel_table[:item_id], :integer
    )

    expect(described_class.values(sources)).to eq([TrackedComment.last.id, 41, 42])
    expect(described_class.values([narrowed])).to eq([article.id])
    expect(described_class.values([])).to eq([])
  end
end
