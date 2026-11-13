# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :collector_pins, force: true do |table|
    table.integer :article_id, null: false
    table.references :pinnable, polymorphic: true
    table.timestamps null: false
  end

  create_table :collector_teams, force: true do |table|
    table.string :name
    table.timestamps null: false
  end

  create_table :collector_seats, force: true do |table|
    table.integer :team_id
    table.integer :user_id
    table.timestamps null: false
  end

  create_table :collector_users, force: true do |table|
    table.string :name
    table.timestamps null: false
  end
end

# A through over a through whose source is a belongs_to.
class CollectorTeam < ActiveRecord::Base
  has_many :seats, class_name: 'CollectorSeat', foreign_key: :team_id
  has_many :users, through: :seats
  has_many :user_seats, through: :users, source: :seats
  has_paper_trail
end

class CollectorSeat < ActiveRecord::Base
  belongs_to :team, class_name: 'CollectorTeam', optional: true
  belongs_to :user, class_name: 'CollectorUser', optional: true
  has_paper_trail
end

class CollectorUser < ActiveRecord::Base
  has_many :seats, class_name: 'CollectorSeat', foreign_key: :user_id
  has_paper_trail
end

class CollectorArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  has_many :pins, class_name: 'CollectorPin', foreign_key: :article_id, inverse_of: :article
  has_many :pinned_authors, through: :pins, source: :pinnable, source_type: 'TrackedAuthor'
  # Active Record takes the type as a symbol too.
  has_many :pinned_tags, through: :pins, source: :pinnable, source_type: :TrackedTag
  has_paper_trail
end

class CollectorPin < ActiveRecord::Base
  belongs_to :article, class_name: 'CollectorArticle', inverse_of: :pins
  belongs_to :pinnable, polymorphic: true
  has_paper_trail
end

# Throughs that go through, or reach, another through.
class CollectorAuthor < ActiveRecord::Base
  self.table_name = 'tracked_authors'
  has_many :posts, class_name: 'CollectorPost', foreign_key: :author_id, inverse_of: :author
  has_many :notes, through: :posts
  has_many :answers, through: :notes
  has_many :post_answers, through: :posts, source: :answers
  has_paper_trail
end

class CollectorPost < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  belongs_to :author, class_name: 'CollectorAuthor', inverse_of: :posts
  has_many :notes, class_name: 'CollectorNote', foreign_key: :article_id, inverse_of: :post
  has_many :answers, through: :notes
  has_paper_trail
end

class CollectorNote < ActiveRecord::Base
  self.table_name = 'tracked_comments'
  belongs_to :post, class_name: 'CollectorPost', foreign_key: :article_id, inverse_of: :notes
  has_many :answers, class_name: 'CollectorAnswer', foreign_key: :comment_id, inverse_of: :note
  has_paper_trail
end

class CollectorAnswer < ActiveRecord::Base
  self.table_name = 'tracked_replies'
  belongs_to :note, class_name: 'CollectorNote', foreign_key: :comment_id, inverse_of: :answers
  has_paper_trail
end

RSpec.describe PaperTrailDiff::ActivityVersionCollector do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    ActiveRecord::Base.connection.execute('DELETE FROM tracked_articles_tags')
    [CollectorSeat, CollectorUser, CollectorTeam, CollectorPin, TrackedReply, TrackedComment,
     TrackedProfile, TrackedAuthorship,
     TrackedArticle, TrackedAuthor, TrackedTag].each(&:delete_all)
  end

  def versions_of(record)
    record.versions.reorder(:created_at, :id).to_a
  end

  # Collects from the record's first version to its last, from the history
  # prepared for them, along `paths` or another tree over the same history.
  # A block is given the prepared index first.
  def collect(record, paths, tree: paths)
    root_versions = versions_of(record)
    adapter = PaperTrailDiff::PaperTrailAdapter.new(
      associations: paths, ignore: PaperTrailDiff::DEFAULT_IGNORED_ATTRIBUTES
    )
    snapshots = adapter.instance_variable_get(:@activity_snapshotter).prepare(record, root_versions)
    index = snapshots&.activity_index
    yield index if block_given?
    described_class.new(record, root_versions: root_versions, traversal: traversal(tree),
                                range_start: root_versions.first, range_end: root_versions.last,
                                prepared: index).call
  end

  def traversal(paths)
    PaperTrailDiff::AssociationTraversal.new(PaperTrailDiff::AssociationTree.build(paths))
  end

  # Each event's version type and event, its branches, and whether it is a
  # through's join row.
  def described(events)
    events.map do |event|
      [event.version.item_type, event.version.event, event.branches, event.joins]
    end
  end

  # Saves the article again from a fresh read: PT-AT records HABTM members from
  # the saving instance, which never forgets the ones it was given.
  def save_again(article, title)
    article.class.find(article.id).update!(title: title)
  end

  it 'collects the root versions alone, as root events, for no associations' do
    article = TrackedArticle.create!(title: 'Draft')
    article.update!(title: 'Final')

    events = collect(article, [])

    expect(described(events)).to eq([['TrackedArticle', 'create', nil, []],
                                     ['TrackedArticle', 'update', nil, []]])
    expect(events).to be_frozen
  end

  it 'credits a version to the top-level association it was reached through' do
    article = TrackedArticle.create!(title: 'Draft')
    article.comments.create!(body: 'First').replies.create!(body: 'Reply')
    TrackedProfile.create!(article: article, bio: 'Bio')
    save_again(article, 'Final')

    expect(described(collect(article, [{ comments: :replies }, :profile]))).to eq(
      [['TrackedArticle', 'create', nil, []], ['TrackedComment', 'create', ['comments'], []],
       ['TrackedReply', 'create', ['comments'], []],
       ['TrackedProfile', 'create', ['profile'], []], ['TrackedArticle', 'update', nil, []]]
    )
  end

  it 'credits a version reached through two associations to both' do
    author = TrackedAuthor.create!(name: 'Ann')
    article = TrackedArticle.create!(title: 'Draft', author: author)
    TrackedAuthorship.create!(article: article, author: author, role: 'editor')
    author.update!(name: 'Ann B.')
    save_again(article, 'Final')

    events = described(collect(article, %i[author contributors]))

    expect(events).to include(['TrackedAuthor', 'update', %w[author contributors], []])
  end

  it 'collects every target the root pointed at in the range' do
    first, second = %w[Ann Bea].map { |name| TrackedAuthor.create!(name: name) }
    article = TrackedArticle.create!(title: 'Draft', author: first)
    first.update!(name: 'Ann B.')
    article.update!(author: second)
    second.update!(name: 'Bea C.')
    save_again(article, 'Final')

    expect(described(collect(article, [:author])).select { |type,| type == 'TrackedAuthor' })
      .to eq([['TrackedAuthor', 'update', ['author'], []],
              ['TrackedAuthor', 'update', ['author'], []]])
  end

  # A target with no state there has nothing to compare, as when PT-AT's
  # record of a key names one no loaded state of the owner does.
  it 'leaves out a target prepared history did not load' do
    first, second = %w[Ann Bea].map { |name| TrackedAuthor.create!(name: name) }
    article = TrackedArticle.create!(title: 'Draft', author: first)
    first.update!(name: 'Ann B.')
    article.update!(author: second)
    second.update!(name: 'Bea C.')
    save_again(article, 'Final')

    events = collect(article, [:author]) do |index|
      allow(index).to receive(:loaded?).and_call_original
      allow(index).to receive(:loaded?).with(TrackedAuthor, second.id).and_return(false)
    end

    expect(described(events).select { |type,| type == 'TrackedAuthor' })
      .to eq([['TrackedAuthor', 'update', ['author'], []]])
    expect(events.map(&:version)).to include(first.versions.last)
  end

  it 'reads nothing past an association with no records in the range' do
    article = TrackedArticle.create!(title: 'Draft')
    save_again(article, 'Final')

    expect(described(collect(article, [:contributors, { comments: :replies }])).map(&:first))
      .to eq(%w[TrackedArticle TrackedArticle])
  end

  it 'collects the members each root version recorded' do
    article = TrackedArticle.create!(title: 'Draft')
    tag = TrackedTag.create!(name: 'ruby')
    article.tags << tag
    TrackedArticle.transaction { TrackedArticle.find(article.id).paper_trail.save_with_version }
    tag.update!(name: 'Ruby')
    save_again(article, 'Final')

    expect(described(collect(article, [:tags])).select { |type,| type == 'TrackedTag' })
      .to eq([['TrackedTag', 'create', ['tags'], []], ['TrackedTag', 'update', ['tags'], []]])
  end

  it "collects a through's join rows as joins, then its targets" do
    article = TrackedArticle.create!(title: 'Draft')
    author = TrackedAuthor.create!(name: 'Ann')
    TrackedAuthorship.create!(article: article, author: author, role: 'editor')
    author.update!(name: 'Ann B.')
    save_again(article, 'Final')

    expect(described(collect(article, [:contributors]))).to eq(
      [['TrackedArticle', 'create', nil, []],
       ['TrackedAuthor', 'create', ['contributors'], []],
       ['TrackedAuthorship', 'create', ['contributors'], ['contributors']],
       ['TrackedAuthor', 'update', ['contributors'], []],
       ['TrackedArticle', 'update', nil, []]]
    )
  end

  # One pin's recorded type names a model since removed: it has no versions.
  it 'collects only the targets of the type a through names' do
    article = CollectorArticle.create!(title: 'Draft')
    author = TrackedAuthor.create!(name: 'Ann')
    CollectorPin.create!(article: article, pinnable: author)
    CollectorPin.create!(article: article, pinnable: TrackedTag.create!(name: 'ruby'))
    gone = CollectorPin.create!(article: article, pinnable: TrackedTag.create!(name: 'gone'))
    PaperTrail::VersionAssociation.joins(:version)
                                  .where(versions: { item_type: 'CollectorPin', item_id: gone.id })
                                  .update_all(foreign_type: 'RemovedModel')
    author.update!(name: 'Ann B.')
    save_again(article, 'Final')

    authors = described(collect(article, [:pinned_authors])).map(&:first)
    tags = described(collect(article, [:pinned_tags])).map(&:first)

    expect(authors).to include('TrackedAuthor', 'CollectorPin')
    expect(authors).not_to include('TrackedTag')
    expect(tags).to include('TrackedTag')
    expect(tags).not_to include('TrackedAuthor')
  end

  it 'collects the joins of a through that goes through another, under its own branch' do
    author = CollectorAuthor.create!(name: 'Ann')
    post = CollectorPost.create!(title: 'Post', author: author)
    CollectorNote.create!(post: post, body: 'Note').answers.create!(body: 'Answer')
    CollectorAuthor.find(author.id).update!(name: 'Ann B.')

    expect(described(collect(author, [:answers]))).to eq(
      [['CollectorAuthor', 'create', nil, []],
       ['CollectorPost', 'create', ['answers'], ['answers']],
       ['CollectorNote', 'create', ['answers'], ['answers']],
       ['CollectorAnswer', 'create', ['answers'], []], ['CollectorAuthor', 'update', nil, []]]
    )
  end

  # The user is a join row of `user_seats` only while a seat of the team
  # names it, which its own state cannot show.
  it 'collects the middle rows of a through over a through only while a row leads to them' do
    team = CollectorTeam.create!(name: 'Team')
    user = CollectorUser.create!(name: 'Before')
    seat = CollectorSeat.create!(team: team)
    user.update!(name: 'Still before')
    seat.update!(user: user)
    user.update!(name: 'Seated')
    team.update!(name: 'Team B')

    users = described(collect(team, [:user_seats])).select { |type, *| type == 'CollectorUser' }

    expect(users).to eq([['CollectorUser', 'update', ['user_seats'], ['user_seats']]])
  end

  it 'collects the joins of a through that reaches another, under its own branch' do
    author = CollectorAuthor.create!(name: 'Ann')
    post = CollectorPost.create!(title: 'Post', author: author)
    CollectorNote.create!(post: post, body: 'Note').answers.create!(body: 'Answer')
    CollectorAuthor.find(author.id).update!(name: 'Ann B.')

    joins = described(collect(author, [:post_answers])).select { |*, joins| joins.any? }

    expect(joins).to eq([['CollectorPost', 'create', ['post_answers'], ['post_answers']],
                         ['CollectorNote', 'create', ['post_answers'], ['post_answers']]])
  end

  it 'names an association it cannot read by its whole path' do
    article = TrackedArticle.create!(title: 'Draft')
    article.comments.create!(body: 'Comment')
    save_again(article, 'Final')

    expect { collect(article, [:comments], tree: [{ comments: :missing }]) }
      .to raise_error(PaperTrailDiff::UnknownAssociationError,
                      'unknown association: comments.missing')
  end

  # Ids follow the order of saving, which a version's time need not.
  it 'orders events by time rather than by id' do
    article = TrackedArticle.create!(title: 'Draft')
    article.update!(title: 'Final')
    comment = article.comments.create!(body: 'Saved last, dated between')
    created, updated = versions_of(article)
    start = Time.utc(2032, 1, 1, 12)
    created.update_columns(created_at: start)
    updated.update_columns(created_at: start + 10)
    comment.versions.sole.update_columns(created_at: start + 5)

    expect(described(collect(article, [:comments])).map(&:first))
      .to eq(%w[TrackedArticle TrackedComment TrackedArticle])
  end

  # Each version table counts its own ids, so ids from two tables cannot
  # order versions saved at one time.
  it 'refuses events it cannot order' do
    article = TrackedArticle.create!(title: 'Tied')
    version = lambda do |table, id, seconds|
      Struct.new(:id, :created_at, :item_type, :item_id) do
        define_singleton_method(:table_name) { table }
      end.new(id, Time.utc(2026, 1, 1) + seconds, 'TrackedArticle', article.id)
    end
    tied = [version.call('versions', 1, 0), version.call('comments', 2, 0)]
    later = version.call('versions', 3, 1)
    # Given out of order, the tie is found once they are in order.
    collector = described_class.new(article, root_versions: [tied.first, later, tied.last],
                                             traversal: traversal([]),
                                             range_start: tied.first, range_end: later,
                                             prepared: nil)

    expect { collector.call }.to raise_error(
      PaperTrailDiff::AmbiguousVersionOrderError,
      PaperTrailDiff::Support.ambiguous_message(PaperTrailDiff::Support.ambiguous_pair(tied))
    )
  end
end
