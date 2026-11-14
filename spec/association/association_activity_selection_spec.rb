# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/string_item_database'
require_relative '../support/source_type_database'

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
     UnversionedAttachment, SourceTypeLink, SourceTypeHolder, SourceTypeAuthor,
     SourceTypeTag].each(&:delete_all)
    StringItemVersionAssociation.delete_all
    StringItemVersion.delete_all
    [StringItemNote, StringItemPost].each(&:delete_all)
  end

  def traversal(paths)
    PaperTrailDiff::AssociationTraversal.new(PaperTrailDiff::AssociationTree.build(paths))
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

  # The window reports a transaction that ends inside it, so it selects the
  # records such a transaction saved before the window began.
  describe 'over a window a transaction crosses',
           mutant_expression: %w[PaperTrailDiff::AssociationActivitySelection
                                 PaperTrailDiff::ScopedRootSelection] do
    it 'selects an article whose comment a transaction open at the start changed before it' do
      TrackedArticle.create!(title: 'Earlier').comments.create!(body: 'before the window')
      article = TrackedArticle.create!(title: 'Quiet')
      comment = article.comments.create!(body: 'one')
      window_start = nil
      ActiveRecord::Base.transaction do
        comment.update!(body: 'two')
        window_start = Time.now.utc
        TrackedTag.create!(name: 'unrelated')
      end
      window = PaperTrailDiff::TimeRange.new(window_start..Time.now.utc)
      widened = lambda do |paths, range = window|
        described_class.window(TrackedArticle, traversal(paths), range)
      end

      expect(scope_ids([:comments], window.to_range)).to eq([article.id])
      expect(scope_ids([], window.to_range)).to eq([])
      expect(widened.call([:comments]).begin_time).to eq(comment.versions.last.created_at)
      expect([widened.call([]), described_class.window(TrackedArticle, nil, window)])
        .to all(equal(window))
      expect(widened.call([:comments], nil)).to be_nil
    end

    # Only the transactions open at the start are reported before it, so the
    # versions of any other there select nothing, a root's own or a child's.
    it 'selects no record that only a transaction ended before the start changed' do
      edited = TrackedArticle.create!(title: 'Edited before')
      commented = TrackedArticle.create!(title: 'Commented before')
      gone = TrackedArticle.create!(title: 'Destroyed before')
      job = TrackedTag.create!(name: 'job starts')
      edited.update!(title: 'Edited')
      commented.comments.create!(body: 'before the window')
      gone.destroy!
      window_start = Time.now.utc
      job.update!(name: 'job ends')
      job.versions.update_all(transaction_id: 9_000_000)
      window = window_start..Time.now.utc

      expect(scope_ids([:comments], window)).to eq([])
      expect(PaperTrailDiff.report(TrackedArticle, since: window_start, limit: 1,
                                                   associations: [:comments], include_deleted: true)
                           .unreachable).to eq([])
    end
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

  # Only links of the source type are members: a renamed tag sharing an
  # author's id, or a change to a link that names a tag on both sides of it,
  # selects nothing.
  it 'selects through a source_type only for authors and links of that type' do
    author = SourceTypeAuthor.create!(name: 'Ann')
    tag = SourceTypeTag.create!(name: 'Same id', id: author.id)
    renamed, joined, left, tagged, retagged, earlier = %w[renamed joined left tagged retagged
                                                          earlier].map do |name|
      SourceTypeHolder.create!(name: name)
    end
    SourceTypeLink.create!(holder: renamed, target: author)
    joining = SourceTypeLink.create!(holder: joined, target: tag)
    leaving = SourceTypeLink.create!(holder: left, target: SourceTypeAuthor.create!(name: 'Bea'))
    SourceTypeLink.create!(holder: tagged, target: tag)
    touched = SourceTypeLink.create!(holder: retagged, target: tag, origin: author)
    switched = SourceTypeLink.create!(holder: earlier, target: author)
    switched.update!(target: tag)
    start = Time.now.utc
    [author, tag].each { |record| record.update!(name: "#{record.name} renamed") }
    joining.update!(target: SourceTypeAuthor.create!(name: 'Cy'))
    leaving.update!(target: tag)
    [touched, switched].each(&:touch)

    %i[linked_authors symbol_authors].each do |name|
      analyses, = PaperTrailDiff.analyze_scope(SourceTypeHolder, within: start..Time.now.utc,
                                                                 associations: [name],
                                                                 activity: true, limit: 10)
      expect(analyses.keys.map { |identity| identity.last.to_i }.sort)
        .to eq([renamed.id, joined.id, left.id])
    end
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
      SelectionNote, traversal: traversal([:notable]),
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

  it 'applies the relation and limit: to the records it adds' do
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

    expect(ids(filtered)).to eq([kept.id])
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
                          activity_traversal: traversal(['comments.replies', 'author'])
        ).call
      end
    end

    expect(measure.call(1)).to eq(measure.call(12))
  end

  describe 'its sources' do
    def sources(model, paths, window: nil, version_scope: nil)
      range = PaperTrailDiff::TimeRange.new(window) if window
      described_class.new(model, traversal: traversal(paths),
                                 time_range: range, version_scope: version_scope).call
    end

    def selected(found)
      described_class.values(found).map(&:to_i).sort
    end

    def since(start)
      start..Time.now.utc
    end

    it 'counts only the versions a version scope keeps, at every depth' do
      article = TrackedArticle.create!(title: 'Quiet')
      other = TrackedArticle.create!(title: 'Also quiet')
      comment = other.comments.create!(body: 'by the system')
      start = Time.now.utc
      PaperTrail.request(whodunnit: 'alice') do
        article.comments.create!(body: 'by alice').replies.create!(body: 'and her reply')
      end
      comment.replies.create!(body: 'by the system')
      alice = ->(versions) { versions.where(whodunnit: 'alice') }
      found = lambda do |paths, **options|
        selected(sources(TrackedArticle, paths, window: since(start), **options))
      end

      expect(found.call([:comments], version_scope: alice)).to eq([article.id])
      expect(found.call(['comments.replies'], version_scope: alice)).to eq([article.id])
      expect(found.call(['comments.replies'])).to eq([article.id, other.id].sort)
    end

    it 'keeps a subquery typed like the owner column where the columns compared match' do
      article = TrackedArticle.create!(title: 'Quiet')
      comment = article.comments.create!(body: 'one')
      start = Time.now.utc
      comment.update!(body: 'two')

      found = sources(TrackedArticle, [:comments], window: since(start))

      expect(found.map(&:class)).to eq([described_class::Query] * 2)
      expect(found.map(&:type)).to eq(%i[integer integer])
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
        stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', slice)
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

      expect(query.missing(TrackedComment)).to eq([gone.id])
      expect(kept.id).not_to eq(gone.id)
    end

    it 'names no id of a row the default scope of its model hides' do
      hiding = Class.new(ActiveRecord::Base) do
        self.table_name = 'tracked_comments'
        default_scope { where.not(body: 'hidden') }
      end
      article = TrackedArticle.create!(title: 'Article')
      article.comments.create!(body: 'shown').update!(body: 'hidden')

      expect(query.missing(hiding)).to eq([])
    end

    # PostgreSQL does not plan `NOT IN (SELECT ...)` as an anti-join: it reads
    # every key for the statement, and again for each row once they outgrow
    # its working memory.
    it 'asks for them with NOT EXISTS' do
      sql = []
      callback = ->(*, payload) { sql << payload[:sql].tr('`[]', '"""') }

      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        query.missing(TrackedComment)
      end

      expect(sql.length).to eq(1)
      expect(sql.first).to include(
        'NOT (EXISTS (SELECT "tracked_comments".* FROM "tracked_comments" ' \
        'WHERE "tracked_comments"."id" = "versions"."item_id"))'
      )
      expect(sql.first).not_to include('NOT IN')
    end

    it 'leaves out a key recorded as empty, which names no record' do
      article = TrackedArticle.create!(title: 'Article')
      article.comments.create!(body: 'one')
      rows = PaperTrail::VersionAssociation.where(foreign_key_name: 'article_id')
      keys = described_class.new(rows, PaperTrail::VersionAssociation.arel_table[:foreign_key_id],
                                 :integer)
      TrackedArticle.where(id: article.id).delete_all
      PaperTrail::VersionAssociation.create!(version_id: rows.first.version_id,
                                             foreign_key_name: 'article_id', foreign_key_id: nil)

      expect(keys.missing(TrackedArticle)).to eq([article.id])
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
