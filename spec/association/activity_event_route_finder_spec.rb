# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :route_stickers, force: true do |table|
    table.string :type
    table.integer :article_id, null: false
    table.references :holder, polymorphic: true
    table.timestamps null: false
  end
end

class RouteSticker < ActiveRecord::Base
  belongs_to :article, class_name: 'RouteArticle'
  belongs_to :holder, polymorphic: true, optional: true
  has_paper_trail
end

class RoutePinnedSticker < RouteSticker
end

class RouteArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  has_many :stickers, class_name: 'RouteSticker', foreign_key: :article_id, inverse_of: :article
  # An association to a subclass, and a through it joins.
  has_many :pinned_stickers, class_name: 'RoutePinnedSticker', foreign_key: :article_id
  has_many :pinned_authors, through: :pinned_stickers, source: :holder, source_type: 'TrackedAuthor'
  has_paper_trail
end

RSpec.describe PaperTrailDiff::ActivityEventRouteFinder do
  def finder(paths, model = TrackedArticle)
    tree = PaperTrailDiff::AssociationTree.build(paths)
    [described_class.new(PaperTrailDiff::AssociationTraversal.new(tree)), tree, model]
  end

  # Each route as the names along it and the path it ends at.
  def described(routes)
    routes.map { |route| [route.map(&:first), route.last.last] }
  end

  it 'finds the has_many routes to a type, at any depth' do
    routes, tree, model = finder([{ comments: :replies }, :limited_comments, :profile])
    replies = routes.collection_routes(model, tree, 'TrackedReply')

    expect(described(routes.collection_routes(model, tree, 'TrackedComment')))
      .to eq([[['comments'], 'comments'], [['limited_comments'], 'limited_comments']])
    expect(described(replies)).to eq([[%w[comments replies], 'comments.replies']])
    expect(replies.sole.map { |entry| entry.fetch(2) })
      .to eq([tree.child('comments'), tree.child('comments').child('replies')])
    expect(routes.collection_routes(model, tree, 'TrackedProfile')).to eq([])
  end

  it 'finds a route to a subclass by its base class' do
    routes, tree, model = finder([:pinned_stickers], RouteArticle)

    expect(described(routes.collection_routes(model, tree, 'RouteSticker')))
      .to eq([[['pinned_stickers'], 'pinned_stickers']])
  end

  it 'answers each model, tree, type and path apart' do
    routes, tree, = finder([:comments])
    limited = PaperTrailDiff::AssociationTree.build([:limited_comments])
    replies = PaperTrailDiff::AssociationTree.build([:replies])

    asked = [[TrackedArticle, tree, 'TrackedComment', ''],
             [TrackedAuthor, tree, 'TrackedComment', ''],
             [TrackedArticle, limited, 'TrackedComment', ''],
             [TrackedComment, replies, 'TrackedReply', 'comments'],
             [TrackedComment, replies, 'TrackedReply', 'notes']]
    found = asked.map do |model, within, type, path|
      described(routes.collection_routes(model, within, type, path: path))
    end

    expect(found).to eq([[[['comments'], 'comments']], [],
                         [[['limited_comments'], 'limited_comments']],
                         [[['replies'], 'comments.replies']], [[['replies'], 'notes.replies']]])
  end

  # A through's membership follows its join rows, which a route does not
  # replace.
  it 'finds no has_many route through a through' do
    routes, tree, model = finder([:contributors])

    expect(routes.collection_routes(model, tree, 'TrackedAuthor')).to eq([])
  end

  it 'finds the belongs_to routes to a type, at any depth, but none to a polymorphic target' do
    routes, tree, model = finder([:author, { comments: :reviewer }])
    stickers, sticker_tree, sticker_model = finder([{ stickers: :holder }], RouteArticle)

    expect(described(routes.belongs_to_routes(model, tree, 'TrackedAuthor')))
      .to eq([[['author'], 'author'], [%w[comments reviewer], 'comments.reviewer']])
    expect(stickers.belongs_to_routes(sticker_model, sticker_tree, 'TrackedAuthor')).to eq([])
  end

  it 'keeps the routes it found, frozen, for the same request however its strings change' do
    routes, tree, model = finder([{ comments: :replies }])
    type = +'TrackedReply'
    path = +''

    found = routes.collection_routes(model, tree, type, path: path)
    type << ' changed'
    path << 'changed'

    expect(routes.collection_routes(model, tree, 'TrackedReply')).to equal(found)
    expect(found).to be_frozen.and(all(be_frozen.and(all(be_frozen))))
  end

  it 'tells whether a through in the tree joins through or reaches a type' do
    routes, tree, model = finder([:contributors, { comments: :replies }])
    nested, nested_tree, nested_model = finder([{ articles: :contributors }], TrackedAuthor)
    pinned, pinned_tree, pinned_model = finder([:pinned_authors], RouteArticle)

    expect(%w[TrackedAuthorship TrackedAuthor TrackedComment].map do |type|
      routes.through_part?(model, tree, type)
    end).to eq([true, true, false])
    expect(nested.through_part?(nested_model, nested_tree, 'TrackedAuthorship')).to be(true)
    expect(pinned.through_part?(pinned_model, pinned_tree, 'RouteSticker')).to be(true)
  end

  it 'answers each through question once, for each model, tree and type' do
    tree = PaperTrailDiff::AssociationTree.build([:contributors, { comments: :replies }])
    traversal = PaperTrailDiff::AssociationTraversal.new(tree)
    allow(traversal).to receive(:reflections_for).and_call_original
    routes = described_class.new(traversal)

    asked = [[TrackedArticle, tree, 'TrackedComment'],
             [TrackedArticle, tree, 'TrackedComment'],
             [TrackedArticle, tree, 'TrackedAuthor'],
             [TrackedComment, tree.child('comments'), 'TrackedAuthor']]
    answers = asked.map { |model, within, type| routes.through_part?(model, within, type) }

    # Two levels for the first question, none for it again, both for the
    # third, as `comments` is searched before `contributors`, and one for the
    # last.
    expect(answers).to eq([false, false, true, false])
    expect(traversal).to have_received(:reflections_for).exactly(5).times
  end

  # An article's comments are its own; an author's are a through.
  it 'answers through questions for each model and tree apart' do
    comments = PaperTrailDiff::AssociationTree.build([:comments])
    contributors = PaperTrailDiff::AssociationTree.build([:contributors])
    routes = described_class.new(PaperTrailDiff::AssociationTraversal.new(comments))

    asked = [[TrackedArticle, comments, 'TrackedArticle'],
             [TrackedAuthor, comments, 'TrackedArticle'],
             [TrackedArticle, comments, 'TrackedAuthor'],
             [TrackedArticle, contributors, 'TrackedAuthor']]
    answers = asked.map { |model, tree, type| routes.through_part?(model, tree, type) }

    expect(answers).to eq([false, true, false, true])
  end

  it 'names an association it cannot read by its whole path' do
    routes, tree, model = finder([{ comments: :missing }])

    expect { routes.through_part?(model, tree, 'TrackedAuthor') }
      .to raise_error(PaperTrailDiff::UnknownAssociationError,
                      'unknown association: comments.missing')
  end

  it 'tells a route that passes through a scoped association' do
    routes, tree, model = finder([:comments, { limited_comments: :replies }])
    plain, limited = routes.collection_routes(model, tree, 'TrackedComment')
    past_scope = routes.collection_routes(model, tree, 'TrackedReply')

    asked = [[plain], [plain, limited], past_scope]

    expect(asked.map { |found| described_class.scoped_route?(found) }).to eq([false, true, true])
  end
end
