# frozen_string_literal: true

require_relative '../support/association_database'

# Throughs whose parts are throughs. Declared here, on a class of their own,
# so the shared fixtures keep their association lists.
class LoaderSpecAuthor < ActiveRecord::Base
  self.table_name = 'tracked_authors'
  has_many :articles, class_name: 'TrackedArticle', foreign_key: :author_id, inverse_of: false
  has_many :comments, through: :articles
  has_many :comment_reviewers, through: :comments, source: :reviewer
  has_many :article_contributors, through: :articles, source: :contributors
  has_paper_trail
end

RSpec.describe PaperTrailDiff::PreparedHistoryLoader do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    ActiveRecord::Base.connection.execute('DELETE FROM tracked_articles_tags')
    [TrackedReply, TrackedComment, TrackedAuthorship, TrackedProfile, TrackedArticle,
     TrackedAuthor, TrackedTag, UnversionedAttachment].each(&:delete_all)
  end

  def versions_of(record)
    record.versions.reorder(:created_at, :id).to_a
  end

  def checkpoint(article)
    TrackedArticle.transaction { TrackedArticle.find(article.id).paper_trail.save_with_version }
    versions_of(article).last
  end

  def load_history(record, paths, root_versions: versions_of(record), **options)
    tree = PaperTrailDiff::AssociationTree.build(paths)
    defaults = { root_ids: [record.id], start_at: root_versions.first.created_at, end_at: nil,
                 live_records: [] }
    described_class.new(record, root_versions: root_versions, tree: tree,
                                traversal: PaperTrailDiff::AssociationTraversal.new(tree),
                                **defaults, **options).call
  end

  def reflection(model, name)
    model.reflect_on_association(name)
  end

  def ids(history, model, name, group)
    history.edge(model, reflection(model, name)).fetch(group, {}).fetch(:ids, [])
  end

  def supported?(history, model, name)
    history.send(:supported?, model, reflection(model, name))
  end

  def nodes(history, model)
    history.activity_index.send(:node_ids, model)
  end

  it 'loads each requested edge, nested paths included, and nothing else' do
    article = TrackedArticle.create!(title: 'Root', author: TrackedAuthor.create!(name: 'Ann'))
    comment = article.comments.create!(body: 'comment')
    reply = comment.replies.create!(body: 'reply')
    TrackedProfile.create!(article: article, bio: 'not requested')

    history = load_history(article, ['comments.replies', 'author'])

    expect(ids(history, TrackedArticle, :comments, 'TrackedComment')).to eq([comment.id])
    expect(ids(history, TrackedComment, :replies, 'TrackedReply')).to eq([reply.id])
    expect(ids(history, TrackedArticle, :author, 'TrackedAuthor')).to eq([article.author_id])
    expect(history.edge(TrackedArticle, reflection(TrackedArticle, :profile))).to eq({})
    expect(history.activity_index.loaded?(TrackedReply, reply.id)).to be(true)
    expect(history.activity_index.loaded?(TrackedAuthor, article.author_id)).to be(true)
    expect(history.activity_index.loaded?(TrackedProfile, TrackedProfile.last.id)).to be(false)
    expect(nodes(history, TrackedReply)).to eq([reply.id])
    expect(nodes(history, TrackedArticle)).to eq([article.id])
    handled, after = history.record_after(TrackedComment, comment.id, versions_of(comment).first)
    expect([handled, after.body]).to eq([true, 'comment'])
  end

  it 'prepares every root it is given, as one batch' do
    articles = Array.new(2) { |index| TrackedArticle.create!(title: "Root #{index}") }
    comments = articles.map { |article| article.comments.create!(body: 'comment') }
    versions = articles.flat_map { |article| versions_of(article) }.sort_by(&:created_at)

    history = load_history(articles.first, [:comments], root_versions: versions,
                                                        root_ids: articles.map(&:id))

    expect(ids(history, TrackedArticle, :comments, 'TrackedComment')).to eq(comments.map(&:id))
    expect(nodes(history, TrackedArticle)).to eq(articles.map(&:id))
    expect(articles.map { |article| history.activity_index.loaded?(TrackedArticle, article.id) })
      .to eq([true, true])
  end

  it 'reads the children each root held from start_at on' do
    article = TrackedArticle.create!(title: 'Root')
    gone = article.comments.create!(body: 'gone')
    gone.update!(article: TrackedArticle.create!(title: 'Elsewhere'))
    start_at = Time.now.utc
    kept = article.comments.create!(body: 'kept')
    versions = versions_of(article)

    windowed = load_history(article, [:comments], start_at: start_at)
    defaulted = load_history(article, [:comments], root_versions: versions)

    expect(ids(windowed, TrackedArticle, :comments, 'TrackedComment')).to eq([kept.id])
    expect(ids(defaulted, TrackedArticle, :comments, 'TrackedComment'))
      .to contain_exactly(gone.id, kept.id)
  end

  it 'reads the through rows, then the sources they name' do
    article = TrackedArticle.create!(title: 'Root')
    writer = TrackedAuthor.create!(name: 'Writer')
    editor = TrackedAuthor.create!(name: 'Editor')
    authorships = [writer, editor].map do |author|
      TrackedAuthorship.create!(article: article, author: author, role: 'role')
    end

    history = load_history(article, [:contributors])

    expect(ids(history, TrackedArticle, :contributors, 'TrackedAuthor'))
      .to contain_exactly(writer.id, editor.id)
    expect(ids(history, TrackedArticle, :authorships, 'TrackedAuthorship'))
      .to eq(authorships.map(&:id))
    expect(history.activity_index.loaded?(TrackedAuthorship, authorships.first.id)).to be(true)
    expect(history.activity_index.loaded?(TrackedAuthor, writer.id)).to be(true)
    expect(supported?(history, TrackedArticle, :contributors))
      .to be(true)
  end

  it 'reads a through whose source is a has_many like any other through' do
    author = TrackedAuthor.create!(name: 'Author')
    article = TrackedArticle.create!(title: 'Article', author: author)
    comment = article.comments.create!(body: 'comment')

    history = load_history(author, [:comments])

    expect(ids(history, TrackedAuthor, :comments, 'TrackedComment')).to eq([comment.id])
    expect(ids(history, TrackedArticle, :comments, 'TrackedComment')).to eq([comment.id])
    expect(supported?(history, TrackedAuthor, :comments)).to be(true)
  end

  it 'marks an edge into an unversioned model as unsupported, without loading it' do
    article = TrackedArticle.create!(title: 'Article')
    attachment = UnversionedAttachment.create!(article: article, filename: 'a.txt')

    history = load_history(article, %i[unversioned_attachments comments])

    expect(ids(history, TrackedArticle, :unversioned_attachments, 'UnversionedAttachment'))
      .to eq([attachment.id])
    expect(supported?(history, TrackedArticle, :unversioned_attachments))
      .to be(false)
    expect(supported?(history, TrackedArticle, :comments)).to be(true)
  end

  it 'records the HABTM membership of each root transaction' do
    article = TrackedArticle.create!(title: 'Article')
    tag = TrackedTag.create!(name: 'ruby')
    article.tags << tag
    tagged = checkpoint(article)

    history = load_history(article, [:tags], root_versions: [tagged])

    expect(ids(history, TrackedArticle, :tags, 'TrackedTag')).to eq([tag.id])
    expect(history.instance_variable_get(:@habtm))
      .to eq(%w[TrackedArticle tags] => { tagged.transaction_id.to_s => [tag.id] })
  end

  it 'loads the owners of a belongs_to edge before reading their keys' do
    article = TrackedArticle.create!(title: 'Article')
    reviewer = TrackedAuthor.create!(name: 'Reviewer')
    article.comments.create!(body: 'comment', reviewer: reviewer)

    history = load_history(article, ['comments.reviewer'])

    expect(ids(history, TrackedComment, :reviewer, 'TrackedAuthor')).to eq([reviewer.id])
  end

  it 'reads an edge once for owners reached twice, and only for the new ones' do
    author = TrackedAuthor.create!(name: 'Author')
    article = TrackedArticle.create!(title: 'Root', author: author)
    sibling = TrackedArticle.create!(title: 'Sibling', author: author)
    loads = []
    edge_loader = PaperTrailDiff::PreparedEdgeLoader
    allow(edge_loader).to receive(:new).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap do |loader|
        allow(loader).to receive(:call).and_wrap_original do |call, owner, owner_ids, edge|
          loads << [owner.name, edge.name, owner_ids]
          call.call(owner, owner_ids, edge)
        end
      end
    end

    history = load_history(article, ['author.articles.author'])

    expect(loads).to eq([['TrackedArticle', :author, [article.id]],
                         ['TrackedAuthor', :articles, [author.id]],
                         ['TrackedArticle', :author, [sibling.id]]])
    expect(ids(history, TrackedAuthor, :articles, 'TrackedArticle'))
      .to contain_exactly(article.id, sibling.id)
  end

  def edge_loads
    loads = []
    edge_loader = PaperTrailDiff::PreparedEdgeLoader
    allow(edge_loader).to receive(:new).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap do |loader|
        allow(loader).to receive(:call).and_wrap_original do |call, owner, owner_ids, edge|
          loads << [owner.name, edge.name, owner_ids]
          call.call(owner, owner_ids, edge)
        end
      end
    end
    loads
  end

  it 'does not read an edge again for owners it already read' do
    author = TrackedAuthor.create!(name: 'Author')
    article = TrackedArticle.create!(title: 'Root', author: author)
    sibling = TrackedArticle.create!(title: 'Sibling', author: author)
    article.comments.create!(body: 'comment')
    loads = edge_loads

    load_history(article, ['author.articles.author.articles', 'comments.article.author'])

    expect(loads.select { |owner, name, _ids| [owner, name] == ['TrackedArticle', :author] })
      .to eq([['TrackedArticle', :author, [article.id]],
              ['TrackedArticle', :author, [sibling.id]]])
    expect(loads.count { |owner, name, _ids| [owner, name] == ['TrackedAuthor', :articles] })
      .to eq(1)
  end

  # The article and the author share an id, and both have an `authorships` edge.
  it 'keeps edges of one name on different models, and of one model, apart' do
    article = TrackedArticle.create!(id: 4_400, title: 'Root')
    author = TrackedAuthor.create!(id: 4_400, name: 'Author')
    article.update!(author: author)
    own = TrackedAuthorship.create!(article: article, author: TrackedAuthor.create!(name: 'B'),
                                    role: 'article side')
    written = TrackedAuthorship.create!(article: TrackedArticle.create!(title: 'Other'),
                                        author: author, role: 'author side')
    profile = TrackedProfile.create!(article: article, bio: 'bio')

    history = load_history(article, ['authorships', 'profile', 'author.authorships'])

    expect(ids(history, TrackedArticle, :authorships, 'TrackedAuthorship')).to eq([own.id])
    expect(ids(history, TrackedArticle, :profile, 'TrackedProfile')).to eq([profile.id])
    expect(ids(history, TrackedAuthor, :authorships, 'TrackedAuthorship')).to eq([written.id])
  end

  # Keys are offset from the authors' so that a part read by another key
  # cannot find the same rows.
  it 'prepares each part of a through that is itself a through' do
    TrackedArticle.create!(title: 'Offset')
    author = LoaderSpecAuthor.create!(name: 'Author')
    reviewer, contributor = %w[Reviewer Contributor].map do |name|
      TrackedAuthor.create!(name: name)
    end
    article = TrackedArticle.create!(title: 'Article', author_id: author.id)
    comment = article.comments.create!(body: 'comment', reviewer: reviewer)
    TrackedAuthorship.create!(article: article, author: contributor, role: 'role')

    history = load_history(author, %i[comment_reviewers article_contributors])

    expect(ids(history, LoaderSpecAuthor, :comments, 'TrackedComment')).to eq([comment.id])
    expect(ids(history, LoaderSpecAuthor, :comment_reviewers, 'TrackedAuthor'))
      .to eq([reviewer.id])
    expect(ids(history, TrackedArticle, :contributors, 'TrackedAuthor')).to eq([contributor.id])
    expect(ids(history, LoaderSpecAuthor, :article_contributors, 'TrackedAuthor'))
      .to eq([contributor.id])
  end

  # The author path reads the source edge for the author's authorship first;
  # the article's other authorship is read only by the through path.
  it 'reads through sources of intermediates partly read before' do
    author = TrackedAuthor.create!(name: 'Author')
    article = TrackedArticle.create!(title: 'Root', author: author)
    other = TrackedAuthor.create!(name: 'Other')
    [author, other].each do |contributor|
      TrackedAuthorship.create!(article: article, author: contributor, role: 'role')
    end

    history = load_history(article, ['author.authorships.author', 'contributors'])

    expect(ids(history, TrackedArticle, :contributors, 'TrackedAuthor'))
      .to contain_exactly(author.id, other.id)
  end

  it 'registers the through rows of a through path for activity' do
    article = TrackedArticle.create!(title: 'Root')
    author = TrackedAuthor.create!(name: 'A')
    authorship = TrackedAuthorship.create!(article: article, author: author, role: 'role')

    history = load_history(article, [:contributors])

    expect(nodes(history, TrackedAuthorship)).to eq([authorship.id])
  end

  it 'names a nested path it cannot resolve in full' do
    article = TrackedArticle.create!(title: 'Root')
    article.comments.create!(body: 'comment')

    expect { load_history(article, ['comments.nope']) }
      .to raise_error(PaperTrailDiff::UnknownAssociationError, 'unknown association: comments.nope')
  end

  it 'builds its indexes over the range and live records it was given' do
    article = TrackedArticle.create!(title: 'Root')
    article.paper_trail.save_with_version
    versions = versions_of(article)
    start_at = Time.now.utc - 60
    end_at = Time.now.utc
    live = [article]
    allow(PaperTrailDiff::PreparedRecordIndex).to receive(:new).and_call_original
    allow(PaperTrailDiff::PreparedActivityIndex).to receive(:new).and_call_original
    allow(PaperTrailDiff::PreparedEdgeLoader).to receive(:new).and_call_original

    load_history(article, [:comments], root_versions: versions, start_at: start_at,
                                       end_at: end_at, live_records: live)
    load_history(article, [:comments], root_versions: versions, start_at: start_at)

    expect(PaperTrailDiff::PreparedRecordIndex).to have_received(:new)
      .with(start_at, end_at: end_at, live_records: live)
    expect(PaperTrailDiff::PreparedActivityIndex).to have_received(:new)
      .with(instance_of(PaperTrailDiff::PreparedRecordIndex), versions,
            start_at: start_at, end_at: end_at)
    expect(PaperTrailDiff::PreparedActivityIndex).to have_received(:new)
      .with(instance_of(PaperTrailDiff::PreparedRecordIndex), versions,
            start_at: start_at, end_at: versions.last.created_at)
    expect(PaperTrailDiff::PreparedEdgeLoader).to have_received(:new)
      .with(instance_of(PaperTrailDiff::PreparedRecordIndex), versions, start_at: start_at).twice
  end

  it 'marks an edge with a composite foreign key as unsupported' do
    article = TrackedArticle.create!(title: 'Root')
    tree = PaperTrailDiff::AssociationTree.build([])
    loader = described_class.new(article, root_ids: [article.id],
                                          root_versions: versions_of(article), tree: tree,
                                          traversal: PaperTrailDiff::AssociationTraversal.new(tree),
                                          start_at: nil, end_at: nil, live_records: [])
    history = loader.call
    composite = instance_double(ActiveRecord::Reflection::HasManyReflection,
                                name: :composite,
                                foreign_key: Class.new(Array).new(%w[article_id body]),
                                scope: nil, klass: TrackedComment, polymorphic?: false)
    plain = instance_double(ActiveRecord::Reflection::HasManyReflection,
                            name: :plain, foreign_key: 'article_id', scope: nil,
                            klass: TrackedComment, polymorphic?: false)

    loader.send(:mark_unsupported, TrackedArticle, composite, {})
    loader.send(:mark_unsupported, TrackedArticle, plain, {})

    expect(history.send(:supported?, TrackedArticle, composite)).to be(false)
    expect(history.send(:supported?, TrackedArticle, plain)).to be(true)
  end
end
