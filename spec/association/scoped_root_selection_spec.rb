# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/string_item_database'

# Default scopes that hide a record which still has a row.
class ScopeHiddenArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  default_scope { where.not(title: 'Hidden') }
  has_many :comments, class_name: 'ScopeHiddenComment', foreign_key: :article_id
  has_paper_trail
end

class ScopeHiddenComment < ActiveRecord::Base
  self.table_name = 'tracked_comments'
  belongs_to :article, class_name: 'ScopeHiddenArticle'
  has_paper_trail
end

class ScopeHiddenPost < ActiveRecord::Base
  self.table_name = 'string_item_posts'
  default_scope { where.not(title: 'Hidden') }
  has_paper_trail(**STRING_ITEM_HISTORY)
end

# Articles are versioned with an integer item_id, so candidates stay in
# subqueries; string-item posts are not, so candidates are plucked.
RSpec.describe PaperTrailDiff::ScopedRootSelection do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    StringItemVersionAssociation.delete_all
    StringItemVersion.delete_all
    [TrackedReply, TrackedComment, TrackedArticle, TrackedAuthor, PreparedDocument,
     StringItemNote, StringItemPost].each(&:delete_all)
  end

  def since(start)
    PaperTrailDiff::TimeRange.new(start..Time.now.utc)
  end

  def select(scope, time_range: nil, limit: 10, **options)
    described_class.new(scope, time_range: time_range, limit: limit, **options).call
  end

  def tree(*paths)
    PaperTrailDiff::AssociationTree.build(paths)
  end

  # Pages of at least `min` and at most `max` rows.
  def page_bounds(min, max = min)
    stub_const('PaperTrailDiff::ScopedRootSelection::MIN_PAGE_SIZE', min)
    stub_const('PaperTrailDiff::ScopedRootSelection::MAX_PAGE_SIZE', max)
  end

  # The offset and limit of each page the selection reads.
  def pages
    pages = []
    allow_any_instance_of(described_class).to receive(:record_page)
      .and_wrap_original do |original, *args|
        original.call(*args).tap { |page| pages << [page.offset_value, page.limit_value] }
      end
    pages
  end

  # Each query with its identifiers in double quotes, whatever the adapter
  # quotes them with, so that one pattern reads on every database.
  def queries(&block)
    quote = ActiveRecord::Base.connection.quote_column_name('x')
    sql = []
    callback = lambda do |*, payload|
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])

      sql << payload[:sql].tr("#{quote[0]}#{quote[-1]}", '""')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    sql
  end

  describe 'arguments' do
    it 'takes a model class or a relation over a versioned model' do
      article = TrackedArticle.create!(title: 'One')

      expect(select(TrackedArticle).records).to eq([article])
      expect(select(TrackedArticle.where(id: article.id)).records).to eq([article])
    end

    it 'rejects anything else, naming what it needs' do
      expect { select([TrackedArticle]) }
        .to raise_error(PaperTrailDiff::ConfigurationError,
                        'scope: must be an ActiveRecord relation or model class')
      expect { select(Struct.new(:all).new([])) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /scope: must be/)
      expect { select(Struct.new(:where).new([])) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /scope: must be/)
      expect { select(UnversionedAttachment.where(id: 1)) }
        .to raise_error(PaperTrailDiff::UnversionedAssociationError,
                        'scope: UnversionedAttachment is not versioned, so it has no ' \
                        'history to select from')
    end

    it 'requires a positive Integer limit' do
      [0, -1, 1.0, '1', nil].each do |limit|
        expect { select(TrackedArticle, limit: limit) }
          .to raise_error(PaperTrailDiff::ConfigurationError, 'limit: must be a positive Integer')
      end
      expect { select(TrackedArticle, limit: 1) }.not_to raise_error
    end
  end

  shared_examples 'a selection' do
    it 'selects the roots changed in the window, under the relation, in key order' do
      model.create!(title: 'Before')
      start = Time.now.utc
      changed = model.create!(title: 'Inside')
      filtered = model.create!(title: 'Filtered')
      edited = model.create!(title: 'Edited')
      window = since(start)
      model.create!(title: 'After')

      result = select(model.where.not(title: 'Filtered').order(id: :desc), time_range: window)

      expect(result.records).to eq([edited, changed])
      expect(result.unreachable).to eq([])
      expect(select(model, time_range: window).records).to eq([changed, filtered, edited])
      expect(select(model).records.length).to eq(5)
      expect([result, result.records, result.unreachable]).to all(be_frozen)
    end

    it 'names roots destroyed in the window instead of filtering them' do
      start = Time.now.utc
      live = model.create!(title: 'Live')
      gone = Array.new(2) { |index| model.create!(title: "Gone #{index}") }
      gone.reverse_each(&:destroy!)

      result = select(model.where(title: 'Nothing matches'), time_range: since(start))

      expect(result.records).to eq([])
      # Ids sort as strings, so "10" comes before "9".
      expect(result.unreachable).to eq(gone.map { |record| [model.name, record.id.to_s] }.sort)
      expect(result.unreachable).to all(be_frozen)
      expect(select(model, time_range: since(start)).records).to eq([live])
    end

    # Such a transaction moves the root's window back to take its version in
    # (see TransactionCut).
    it 'selects a root saved before the window in a transaction that saved its paths inside it' do
      root, other = %w[Root Other].map { |title| model.create!(title: title) }
      start = model.transaction do
        root.update!(title: 'Root edited')
        Time.now.utc.tap { other.update!(title: 'Other edited') }
      end
      paths = instance_double(PaperTrailDiff::AssociationTraversal)
      allow(paths).to receive(:path_types).with(model).and_return([model.name])

      expect(select(model, time_range: since(start), traversal: paths).records).to eq([root, other])
      expect(select(model, time_range: since(start)).records).to eq([other])
    end

    it 'selects nothing from an empty window' do
      model.create!(title: 'Before')

      result = select(model, time_range: since(Time.now.utc))

      expect([result.records, result.unreachable]).to eq([[], []])
    end

    it 'keeps the relation limit, offset and order' do
      records = Array.new(4) { |index| model.create!(title: "Record #{index}") }

      expect(select(model.order(id: :desc).offset(1).limit(2)).records)
        .to eq([records[2], records[1]])
      expect(select(model.offset(3)).records).to eq([records[3]])
      expect(select(model.limit(0)).records).to eq([])
    end

    # As request parameters give them.
    it 'reads a limit and an offset given as Strings, as Active Record does' do
      records = Array.new(4) { |index| model.create!(title: "Record #{index}") }

      expect(select(model.order(id: :desc).offset('1').limit('2')).records)
        .to eq([records[2], records[1]])
    end

    it 'tells a root its default scope hides from one that has no row' do
      start = Time.now.utc
      hidden = hidden_model.create!(title: 'Hidden')
      gone = hidden_model.create!(title: 'Gone')
      gone.destroy!

      result = select(hidden_model, time_range: since(start))

      expect(result.records).to eq([])
      expect(result.unreachable).to eq([[hidden_model.name, gone.id.to_s]])
      expect(hidden.id).not_to eq(gone.id)
    end

    it 'counts distinct roots against the limit' do
      Array.new(2) { |index| model.create!(title: "Record #{index}") }

      expect(select(model, limit: 2).records.length).to eq(2)
      expect { select(model, limit: 1) }
        .to raise_error(PaperTrailDiff::BatchLimitExceededError,
                        'scope: selected more than 1 roots; narrow the window or the relation, ' \
                        'or raise limit: to the page size you intend to analyze')
    end
  end

  context 'with an integer item_id' do
    let(:model) { TrackedArticle }
    let(:hidden_model) { ScopeHiddenArticle }

    it_behaves_like 'a selection'

    it 'leaves the candidates in the database' do
      TrackedArticle.create!(title: 'One')

      sql = queries { select(TrackedArticle, time_range: since(Time.now.utc - 60)) }

      plucked = sql.grep(/SELECT DISTINCT "versions"."item_id" FROM "versions"/)

      expect(plucked.length).to eq(1)
      expect(plucked.first).to include('NOT IN (SELECT "tracked_articles"."id"')
      expect(sql.grep(/IN \(SELECT "versions"."item_id"/).length).to eq(1)
    end
  end

  context 'with a string item_id' do
    let(:model) { StringItemPost }
    let(:hidden_model) { ScopeHiddenPost }

    it 'plucks each candidate once and reads live rows in one list per page' do
      posts = Array.new(2) { |index| StringItemPost.create!(title: "Post #{index}") }
      posts.each { |post| post.update!(title: 'Edited') }

      sql = queries { expect(select(StringItemPost).records).to eq(posts) }

      expect(sql.grep(/SELECT DISTINCT "string_item_versions"."item_id"/).length).to eq(1)
      expect(sql.grep(/FROM "string_item_posts" WHERE .* (LIMIT|FETCH NEXT)/).grep(/ OR /))
        .to eq([])
    end

    it_behaves_like 'a selection'

    it 'checks which candidates still exist in pages' do
      posts = Array.new(3) { |index| StringItemPost.create!(title: "Post #{index}") }
      stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 2)

      sql = queries { expect(select(StringItemPost).records).to eq(posts) }

      expect(sql.grep(/SELECT "string_item_posts"."id" FROM "string_item_posts" WHERE/).length)
        .to eq(2)
    end

    # Each page lists every candidate, so the pages are as long as the
    # selection can be: one past the limit, at least MIN_PAGE_SIZE and at most
    # MAX_PAGE_SIZE.
    describe 'reading the candidates' do
      before { page_bounds(2, 2_000) }

      it 'reads them in pages of one past the limit' do
        posts = Array.new(5) { |index| StringItemPost.create!(title: "Post #{index}") }
        read = pages

        expect(select(StringItemPost).records).to eq(posts)
        expect(read).to eq([[0, 11]])
      end

      it 'reads at least MIN_PAGE_SIZE records a page' do
        page_bounds(3, 2_000)
        post = StringItemPost.create!(title: 'Post')
        read = pages

        expect(select(StringItemPost, limit: 1).records).to eq([post])
        expect(read).to eq([[0, 3]])
      end

      it 'reads at most MAX_PAGE_SIZE records a page' do
        page_bounds(2, 3)
        posts = Array.new(5) { |index| StringItemPost.create!(title: "Post #{index}") }
        read = pages

        expect(select(StringItemPost).records).to eq(posts)
        expect(read).to eq([[0, 3], [3, 3]])
      end

      it 'reads one past the limit before raising' do
        5.times { |index| StringItemPost.create!(title: "Post #{index}") }
        read = pages

        expect { select(StringItemPost, limit: 3) }
          .to raise_error(PaperTrailDiff::BatchLimitExceededError, /more than 3 roots/)
        expect(read).to eq([[0, 4]])
      end
    end
  end

  # A plain document's versions share the base class's item_type, and its
  # row still exists, so it is neither selected nor named destroyed.
  it 'selects an STI subclass by the versions of its base class' do
    start = Time.now.utc
    special = PreparedSpecialDocument.create!(name: 'Special')
    PreparedDocument.create!(name: 'Plain')
    gone = PreparedSpecialDocument.create!(name: 'Gone').tap(&:destroy!)

    result = select(PreparedSpecialDocument, time_range: since(start))

    expect(result.records).to eq([special])
    expect(result.unreachable).to eq([['PreparedDocument', gone.id.to_s]])
  end

  describe 'ordering' do
    def page_sql(scope)
      queries { select(scope) }.grep(/FROM "tracked_articles"/).grep(/LIMIT|FETCH NEXT/).first
    end

    # Pages hold only under a total order; see TotalOrder.
    it 'reads pages in the relation order, completed by the key' do
      TrackedArticle.create!(title: 'One')

      expect(page_sql(TrackedArticle)).to include('ORDER BY "tracked_articles"."id" ASC')
      expect(page_sql(TrackedArticle.order(title: :desc)))
        .to include('ORDER BY "tracked_articles"."title" DESC, "tracked_articles"."id" ASC')
    end
  end

  describe 'reading pages' do
    it 'reads the relation in pages until a short page, keeping each root once' do
      article = TrackedArticle.create!(title: 'Repeated')
      other = TrackedArticle.create!(title: 'Other')
      3.times { article.comments.create!(body: 'join') }
      2.times { other.comments.create!(body: 'join') }
      page_bounds(2)
      scope = TrackedArticle.joins(:comments).order('tracked_comments.id')
      read = pages

      sql = queries { expect(select(scope).records).to eq([article, other]) }

      expect(sql.grep(/FROM "tracked_articles" INNER JOIN/).length).to eq(3)
      expect(read).to eq([[0, 2], [2, 2], [4, 2]])
    end

    # A page reads the candidates again, so the pages are as long as the
    # selection can be, as for a list of candidates.
    it 'reads the relation in pages of one past the limit' do
      TrackedArticle.create!(title: 'One')
      read = pages

      select(TrackedArticle, limit: 300)

      expect(read).to eq([[0, 301]])
    end

    # A database may return rows that tie in a different order for each page,
    # as PostgreSQL does, so that pages skip some records and repeat others
    # unless the key completes the order.
    it 'reads every record once under an order with ties' do
      articles = Array.new(40) { |index| TrackedArticle.create!(title: %w[b a][index % 2]) }
      page_bounds(4)

      records = select(TrackedArticle.order(title: :desc), limit: 40).records

      expect(records).to eq(articles.partition { |article| article.title == 'b' }.flatten)
    end

    # Each row is a group, which PostgreSQL, MySQL and SQL Server sort only
    # by what it groups or aggregates, not by the key.
    it 'reads a relation grouped by anything but the key in its own order' do
      articles = %w[b a b a].map { |title| TrackedArticle.create!(title: title) }
      latest = TrackedArticle.select('MAX(tracked_articles.id) AS id').group(:title)

      expect(select(latest.order(:title)).records.map(&:id)).to eq([articles[3].id, articles[2].id])
    end

    it 'stops at the relation limit without a query past it' do
      articles = Array.new(5) { |index| TrackedArticle.create!(title: "Article #{index}") }
      page_bounds(2)

      sql = queries do
        expect(select(TrackedArticle.offset(1).limit(4)).records).to eq(articles[1, 4])
      end

      expect(sql.grep(/FROM "tracked_articles" WHERE/).length).to eq(2)
    end

    it 'rejects too many roots as soon as a page holds them' do
      3.times { |index| TrackedArticle.create!(title: "Article #{index}") }
      page_bounds(1)

      expect { select(TrackedArticle, limit: 2) }
        .to raise_error(PaperTrailDiff::BatchLimitExceededError, /more than 2 roots/)
    end
  end

  describe 'historical_filter:' do
    it 'filters plucked candidates by their state in the window' do
      start = Time.now.utc
      kept = TrackedArticle.create!(title: 'Draft')
      kept.update!(title: 'Published')
      TrackedArticle.create!(title: 'Draft')

      result = select(TrackedArticle, time_range: since(start),
                                      historical_filter: { 'title' => 'Draft' })
      empty = select(TrackedArticle, time_range: since(Time.now.utc),
                                     historical_filter: { 'title' => 'Draft' })

      expect(result.records.map(&:id)).to eq(TrackedArticle.order(:id).ids)
      expect(select(TrackedArticle, time_range: since(start),
                                    historical_filter: { 'title' => 'Published' }).records)
        .to eq([kept])
      expect([empty.records, empty.unreachable]).to eq([[], []])
    end

    # Each author's latest article among those that were drafts: the
    # relation groups the records that match, not the candidates.
    it 'groups the records that match under a grouped relation' do
      start = Time.now.utc
      ann, bea = %w[Ann Bea].map { |name| TrackedAuthor.create!(name: name) }
      ann_draft, = [['Draft', ann], ['Other', ann], ['Draft', bea], ['Draft', bea]]
                   .map { |title, author| TrackedArticle.create!(title: title, author: author) }
      latest = TrackedArticle.select('MAX(tracked_articles.id) AS id').group(:author_id)
                             .order(:author_id)

      result = select(latest, time_range: since(start), historical_filter: { 'title' => 'Draft' })

      expect(result.records.map(&:id)).to eq([ann_draft.id, TrackedArticle.maximum(:id)])
    end

    it 'reads states from the window only' do
      article = TrackedArticle.create!(title: 'Old')
      article.update!(title: 'Draft')
      start = Time.now.utc
      article.update!(title: 'Final')

      expect(select(TrackedArticle, time_range: since(start),
                                    historical_filter: { 'title' => 'Old' }).records).to eq([])
    end

    # A busy neighbour's matching records cost nothing and count for nothing.
    it 'reads the history of the relation\'s records only' do
      start = Time.now.utc
      mine, other = %w[Mine Other].map { |name| TrackedAuthor.create!(name: name) }
      kept = TrackedArticle.create!(title: 'Draft', author: mine)
      3.times { TrackedArticle.create!(title: 'Draft', author: other) }

      result = select(TrackedArticle.where(author_id: mine.id),
                      time_range: since(start), limit: 1, max_filter_versions: 2,
                      historical_filter: { 'title' => 'Draft' })

      expect(result.records).to eq([kept])
    end

    # A join that repeats a record still selects it once.
    it 'counts a record the relation repeats once' do
      start = Time.now.utc
      article = TrackedArticle.create!(title: 'Draft')
      2.times { |index| article.comments.create!(body: "Comment #{index}") }

      result = select(TrackedArticle.joins(:comments),
                      time_range: since(start), limit: 1, historical_filter: { 'title' => 'Draft' })

      expect(result.records).to eq([article])
    end

    # As without a filter, they are listed but do not count toward the limit.
    it 'tests deleted records, which no relation can select' do
      start = Time.now.utc
      kept = TrackedArticle.create!(title: 'Draft')
      gone = Array.new(2) { TrackedArticle.create!(title: 'Draft').tap(&:destroy!) }
      TrackedArticle.create!(title: 'Other').destroy!

      result = select(TrackedArticle.where(id: kept.id), time_range: since(start), limit: 1,
                                                         historical_filter: { 'title' => 'Draft' })

      expect(result.records).to eq([kept])
      expect(result.unreachable)
        .to match_array(gone.map { |article| ['TrackedArticle', article.id.to_s] })
    end

    # The relation's order and page choose among the records that match.
    it 'pages the records that match, not the candidates' do
      start = Time.now.utc
      first, _other, second, _third = %w[Draft Other Draft Draft].map do |title|
        TrackedArticle.create!(title: title)
      end

      result = select(TrackedArticle.order(:id).limit(1).offset(1),
                      time_range: since(start), historical_filter: { 'title' => 'Draft' })

      expect(result.records).to eq([second])
      expect(first.id).to be < second.id
    end

    # Ordering by a name the select list gives needs that list.
    it 'reads a relation ordered by a column it selects' do
      start = Time.now.utc
      article = TrackedArticle.create!(title: 'Draft')
      relation = TrackedArticle.select('tracked_articles.*, title AS sort_title')
                               .order('sort_title')

      result = select(relation, time_range: since(start),
                                historical_filter: { 'title' => 'Draft' })

      expect(result.records).to eq([article])
    end

    it 'passes its version budget on' do
      start = Time.now.utc
      article = TrackedArticle.create!(title: 'Draft')
      2.times { |index| article.update!(title: "Draft #{index}") }

      expect do
        select(TrackedArticle, time_range: since(start), historical_filter: { 'title' => 'Draft' },
                               max_filter_versions: 1)
      end.to raise_error(PaperTrailDiff::FilterLimitExceededError, /max_filter_versions: 1/)
    end
  end

  describe 'version_scope:' do
    def by_people = ->(versions) { versions.where.not(whodunnit: nil) }

    it 'selects a root by its own versions only when the scope keeps one' do
      start = Time.now.utc
      by_system = TrackedArticle.create!(title: 'System')
      by_alice = PaperTrail.request(whodunnit: 'alice') { TrackedArticle.create!(title: 'Alice') }

      expect(select(TrackedArticle, time_range: since(start), version_scope: by_people).records)
        .to eq([by_alice])
      expect(select(TrackedArticle, time_range: since(start)).records).to eq([by_system, by_alice])
    end

    it 'names only the destroyed roots whose versions the scope keeps' do
      start = Time.now.utc
      by_system = TrackedArticle.create!(title: 'System')
      by_alice = PaperTrail.request(whodunnit: 'alice') do
        TrackedArticle.create!(title: 'Alice').tap(&:destroy!)
      end
      by_system.destroy!

      result = select(TrackedArticle, time_range: since(start), version_scope: by_people)

      expect(result.unreachable).to eq([['TrackedArticle', by_alice.id.to_s]])
    end

    it 'selects a root through its requested associations only by versions the scope keeps' do
      article = TrackedArticle.create!(title: 'Quiet')
      other = TrackedArticle.create!(title: 'Also quiet')
      start = Time.now.utc
      PaperTrail.request(whodunnit: 'alice') { article.comments.create!(body: 'by alice') }
      other.comments.create!(body: 'by the system')
      options = { time_range: since(start), activity_tree: tree(:comments) }

      expect(select(TrackedArticle, **options, version_scope: by_people).records).to eq([article])
      expect(select(TrackedArticle, **options).records).to eq([article, other])
    end

    it 'rejects a scope that cannot be called' do
      expect { select(TrackedArticle, version_scope: :people) }
        .to raise_error(PaperTrailDiff::ConfigurationError, 'version_scope: must respond to call')
    end
  end

  describe 'activity_tree:' do
    it 'adds roots whose requested associations changed, and names those destroyed' do
      quiet = TrackedArticle.create!(title: 'Quiet')
      gone = TrackedArticle.create!(title: 'Gone')
      untouched = TrackedArticle.create!(title: 'Untouched')
      comments = [quiet, gone, untouched].map { |article| article.comments.create!(body: 'one') }
      start = Time.now.utc
      comments.first(2).each { |comment| comment.update!(body: 'two') }
      TrackedArticle.where(id: gone.id).delete_all

      result = select(TrackedArticle, time_range: since(start), activity_tree: tree(:comments))

      expect(result.records).to eq([quiet])
      expect(result.unreachable).to eq([['TrackedArticle', gone.id.to_s]])
      expect(select(TrackedArticle, time_range: since(start), activity_tree: tree).records)
        .to eq([])
    end

    it 'merges plucked association ids with a root that changed itself' do
      quiet = StringItemPost.create!(title: 'Quiet')
      note = quiet.notes.create!(body: 'one')
      both = StringItemPost.create!(title: 'Both')
      both_note = both.notes.create!(body: 'one')
      start = Time.now.utc
      edited = StringItemPost.create!(title: 'Edited')
      note.update!(body: 'two')
      both.update!(title: 'Both, edited')
      both_note.update!(body: 'two')

      result = select(StringItemPost, time_range: since(start), activity_tree: tree(:notes))

      expect(result.records).to eq([quiet, both, edited])
      expect(result.unreachable).to eq([])
    end

    it 'names a root destroyed in the window once, however it was found' do
      article = TrackedArticle.create!(title: 'Gone')
      comment = article.comments.create!(body: 'one')
      start = Time.now.utc
      comment.update!(body: 'two')
      article.destroy!

      result = select(TrackedArticle, time_range: since(start), activity_tree: tree(:comments))

      expect(result.unreachable).to eq([['TrackedArticle', article.id.to_s]])
    end

    # The root found by its own versions has the larger id, so only a sort
    # puts the one found through its comment first.
    it 'sorts roots destroyed in the window, however each was found' do
      [[TrackedArticle, :comments], [StringItemPost, :notes]].each do |model, path|
        quiet = model.create!(id: 7_101, title: 'Through a child')
        child = quiet.public_send(path).create!(body: 'one')
        start = Time.now.utc
        child.update!(body: 'two')
        itself = model.create!(id: 7_102, title: 'Itself')
        model.where(id: [quiet.id, itself.id]).delete_all

        result = select(model, time_range: since(start), activity_tree: tree(path))

        expect(result.unreachable).to eq([quiet, itself].map { |root| [model.name, root.id.to_s] })
      end
    end

    it 'plucks the candidates when a source cannot be compared with the key' do
      article = TrackedArticle.create!(title: 'Quiet')
      comment = article.comments.create!(body: 'one')
      start = Time.now.utc
      comment.update!(body: 'two')
      selection = PaperTrailDiff::AssociationActivitySelection
      allow(selection).to receive(:new).and_wrap_original do |original, *args, **options|
        real = original.call(*args, **options)
        instance_double(selection, call: real.call.map do |query|
          selection::Query.new(query.relation, query.column, :string)
        end)
      end

      sql = queries do
        expect(select(TrackedArticle, time_range: since(start), activity_tree: tree(:comments))
                 .records).to eq([article])
      end

      expect(sql.grep(/FROM "tracked_articles" WHERE .*IN \(SELECT "version_associations"/))
        .to eq([])
    end

    it 'does not name a root its default scope hides as destroyed' do
      hidden = ScopeHiddenArticle.create!(title: 'Hidden')
      comment = ScopeHiddenComment.create!(article: hidden, body: 'one')
      start = Time.now.utc
      comment.update!(body: 'two')
      gone = ScopeHiddenArticle.create!(title: 'Gone')
      gone_comment = ScopeHiddenComment.create!(article: gone, body: 'one')
      gone_comment.update!(body: 'two')
      ScopeHiddenArticle.where(id: gone.id).delete_all

      result = select(ScopeHiddenArticle, time_range: since(start), activity_tree: tree(:comments))

      expect(result.records).to eq([])
      expect(result.unreachable).to eq([['ScopeHiddenArticle', gone.id.to_s]])
    end

    it 'keeps matching association sources in subqueries' do
      article = TrackedArticle.create!(title: 'Quiet')
      comment = article.comments.create!(body: 'one')
      start = Time.now.utc
      comment.update!(body: 'two')

      sql = queries do
        expect(select(TrackedArticle, time_range: since(start), activity_tree: tree(:comments))
                 .records).to eq([article])
      end

      expect(sql.grep(/FROM "tracked_articles" WHERE .*IN \(SELECT "version_associations"/).length)
        .to eq(1)
      plucked = sql.grep(/\ASELECT DISTINCT "version_associations"/)
      expect(plucked.reject { |query| query.include?('NOT IN') }).to eq([])
    end

    it 'plucks every source when one source cannot stay a subquery' do
      quiet = TrackedArticle.create!(title: 'Quiet')
      comment = quiet.comments.create!(body: 'one')
      start = Time.now.utc
      comment.update!(body: 'two')
      edited = TrackedArticle.create!(title: 'Edited')
      ids = PaperTrailDiff::AssociationActivitySelection.new(
        TrackedArticle, tree: tree(:comments), time_range: since(start)
      ).call.flat_map(&:values)
      allow(PaperTrailDiff::AssociationActivitySelection).to receive(:new).and_wrap_original do
        |original, *args, **options|
        instance_double(PaperTrailDiff::AssociationActivitySelection, call: [ids]).tap do
          original.call(*args, **options)
        end
      end

      result = select(TrackedArticle, time_range: since(start), activity_tree: tree(:comments))

      expect(result.records).to eq([quiet, edited])
    end
  end
end
