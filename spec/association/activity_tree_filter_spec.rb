# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :tree_boards, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :tree_cards, force: true do |table|
    table.integer :board_id
    table.string :title, null: false
    table.boolean :archived, null: false, default: false
    table.timestamps null: false
  end
end

class TreeBoard < ActiveRecord::Base
  has_many :active_cards, -> { where(archived: false) }, class_name: 'TreeCard',
                                                         foreign_key: :board_id
  has_paper_trail
end

class TreeCard < ActiveRecord::Base
  belongs_to :board, class_name: 'TreeBoard', optional: true
  has_paper_trail
end

TreeFilterVersion = Struct.new(:id, :item_type, :item_id, :transaction_id)

# A record that is in a root's tree at one time in a range brings the versions
# it saved while it belonged elsewhere. Those change nothing the root shows, so
# they are not the root's activity: as a step of their own, they would credit
# the root's own changes to a record outside it.
RSpec.describe PaperTrailDiff::ActivityTreeFilter do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedAuthorship, TrackedComment, TrackedArticle, TrackedAuthor, TreeCard, TreeBoard]
      .each(&:delete_all)
  end

  # Each step as its sources and what it changed, with records read by name.
  def summary(steps, names)
    steps.reject(&:empty?).map do |step|
      [step.sources.map { |source| label(source, names) }, changes(step.diff)]
    end
  end

  def label(source, names)
    "#{names.fetch([source.item_type, source.item_id])} #{source.event}"
  end

  def named(records)
    records.to_h { |name, record| [[record.class.base_class.name, record.id], name] }
  end

  def changes(diff)
    presence = diff.record_presence_change ? ['presence'] : []
    presence + diff.attributes.keys + diff.associations.flat_map do |name, change|
      next ["#{name} #{change.relationship.to.inspect}"] unless change.respond_to?(:added)

      change.added.map { |record| "#{name} +#{record.id}" } +
        change.removed.map { |record| "#{name} -#{record.id}" } +
        change.changed.map { |record| "#{name} ~#{record.record.id}" }
    end
  end

  def every_source(steps)
    steps.flat_map(&:sources).map { |source| [source.item_type, source.item_id] }
  end

  def first_version(record)
    record.versions.reorder(:created_at, :id).first
  end

  # In one save, the article is renamed, a comment is added to it, and a
  # comment on another article is edited. That comment moves to the article
  # afterwards, which is what makes its versions candidates at all.
  def stray_history
    article = TrackedArticle.create!(title: 'Root')
    stray = TrackedArticle.create!(title: 'Elsewhere').comments.create!(body: 'stray')
    added = nil
    TrackedArticle.transaction do
      article.update!(title: 'Renamed')
      added = article.comments.create!(body: 'added')
      stray.update!(body: 'edited elsewhere')
    end
    stray.update!(article: article)
    [article.reload, named('article' => article, 'added' => added, 'stray' => stray)]
  end

  def comment_steps(article, **options)
    PaperTrailDiff.activity_timeline(article, associations: [:comments], **options)
  end

  context 'with a comment edited elsewhere before it moved in' do
    let(:history) { stray_history }
    let(:article) { history.first }
    let(:names) { history.last }

    let(:added) { "comments +#{names.key('added').last}" }
    let(:stray) { article.comments.find(names.key('stray').last) }

    it 'credits the added comment to its own version, not to that edit' do
      steps = comment_steps(article, from: first_version(article), to: article)

      expect(summary(steps, names)).to eq(
        [[['article create'], ['presence']],
         [['article update'], ['title']],
         [['added create'], [added]],
         [['stray update'], ["comments +#{stray.id}"]]]
      )
    end

    it 'leaves that edit out of the transaction group' do
      steps = comment_steps(article, from: first_version(article), to: article,
                                     group: :transaction)

      expect(summary(steps, names).fetch(1)).to eq(
        [['article update', 'added create'], ['title', added]]
      )
    end

    it 'leaves out the comment\'s creation on the other article' do
      steps = comment_steps(article, from: first_version(article), to: article)

      expect(steps.map { |step| label(step.source_boundary, names) })
        .to eq(['article create', 'article update', 'added create', 'stray update'])
    end

    it 'reads a time window and a batch the same way' do
      within = first_version(article).created_at..Time.current
      expected = summary(comment_steps(article, within: within), names)
      batch = PaperTrailDiff.analyze_many([article], within: within, associations: [:comments],
                                                     activity: true)

      expect(summary(batch.values.first.activity_timeline, names)).to eq(expected)
      expect(expected.drop(1)).to eq(summary(comment_steps(article, from: first_version(article),
                                                                    to: article), names).drop(1))
    end

    it 'leaves the edit out of a window that ends before the move' do
      move = stray.versions.reorder(:created_at, :id).last
      within = first_version(article).created_at...move.created_at

      [nil, :transaction].each do |group|
        sources = every_source(comment_steps(article, within: within, group: group))
        expect(sources).not_to include(['TrackedComment', stray.id])
      end
    end
  end

  # The other way round: a comment that left, edited in the article's last
  # save. Only the current record shows it is not there afterwards.
  it 'leaves out a departed comment\'s edit in the last transaction' do
    article = TrackedArticle.create!(title: 'Root')
    comment = article.comments.create!(body: 'first')
    comment.update!(article: TrackedArticle.create!(title: 'Elsewhere'))
    TrackedArticle.transaction do
      article.update!(title: 'Renamed')
      comment.update!(body: 'edited elsewhere')
    end
    names = named('article' => article, 'comment' => comment)

    [nil, :transaction].each do |group|
      steps = comment_steps(article.reload, from: first_version(article), to: article,
                                            group: group)
      expect(steps.flat_map(&:sources).map { |source| label(source, names) })
        .to eq(['article create', 'comment create', 'comment update', 'article update'])
    end
  end

  it 'leaves out a former author\'s rename' do
    first, second = %w[First Second].map { |name| TrackedAuthor.create!(name: name) }
    article = TrackedArticle.create!(title: 'Root', author: first)
    article.update!(author: second)
    first.update!(name: 'First, renamed')
    article.update!(title: 'Renamed')

    steps = PaperTrailDiff.activity_timeline(article.reload, from: first_version(article),
                                                             to: article, associations: [:author])

    expect(steps.map { |step| [step.source_boundary.item_type, step.source_boundary.event] })
      .to eq([%w[TrackedArticle create], %w[TrackedArticle update], %w[TrackedArticle update]])
  end

  # Membership by scope: an archived card has left the board's active cards.
  it 'leaves out a card edited after it left a scope' do
    board = TreeBoard.create!(name: 'Board')
    card = TreeCard.create!(board: board, title: 'Card')
    card.update!(archived: true)
    card.update!(title: 'Edited while archived')
    board.update!(name: 'Renamed')

    steps = PaperTrailDiff.activity_timeline(board.reload, from: first_version(board),
                                                           to: board, associations: [:active_cards])
    events = steps.map { |step| [step.source_boundary.item_type, step.source_boundary.event] }

    expect(events).to eq([%w[TreeBoard create], %w[TreeCard create], %w[TreeCard update],
                          %w[TreeBoard update]])
  end

  describe 'deciding each event' do
    def event(id, item_id, transaction_id, type: 'TrackedComment', **flags)
      version = TreeFilterVersion.new(id, type, item_id, transaction_id)
      PaperTrailDiff::ActivityEvent.new(version: version,
                                        branches: flags.fetch(:branches, ['comments']),
                                        join: flags.fetch(:join, false))
    end

    def root_event(id, transaction_id)
      event(id, 1, transaction_id, type: 'TrackedArticle', branches: nil)
    end

    def record(type, id, **associations)
      PaperTrailDiff::RecordSnapshot.new(type: type, id: id, attributes: {},
                                         associations: associations)
    end

    def collection(*records)
      PaperTrailDiff::AssociationSnapshot.new(kind: :has_many, records: records)
    end

    # The article holding comments with these IDs.
    def holding(*ids)
      comments = ids.map { |id| record('TrackedComment', id) }
      record('TrackedArticle', 1, comments: collection(*comments))
    end

    def decisions(pairs, reported: nil, closing: nil)
      filter = described_class.new(pairs.map(&:first), reported: reported, closing: closing)
      kept = []
      filter.call(pairs) { |event, snapshot, keep| kept << [event.version.id, snapshot, keep] }
      kept
    end

    def kept(pairs, **options)
      decisions(pairs, **options).select(&:last).map(&:first)
    end

    it 'yields every event with its own snapshot, in order' do
      pairs = [[root_event(1, 1), holding(5)], [event(2, 5, 2), holding(5)],
               [root_event(3, 3), holding]]

      expect(decisions(pairs).map { |id, snapshot, _| [id, snapshot] })
        .to eq(pairs.map { |pair, snapshot| [pair.version.id, snapshot] })
    end

    it 'keeps a record in the tree before its transaction or after it' do
      pairs = [[root_event(1, 1), holding(5)], [event(2, 5, 2), holding(5)],
               [event(3, 6, 2), holding(5)], [event(4, 7, 2), holding(5)],
               [root_event(5, 3), holding(5, 6)]]

      expect(kept(pairs)).to eq([1, 2, 3, 5])
    end

    it 'keeps the root\'s events, join rows, and events whose steps are not reported' do
      pairs = [[root_event(1, 1), holding], [event(2, 5, 2, join: true), holding],
               [event(3, 6, 3), holding], [event(4, 7, 4), holding], [root_event(5, 5), holding]]

      expect(kept(pairs, reported: ->(event) { event.version.id != 3 })).to eq([1, 2, 3, 5])
    end

    it 'judges the last transaction by what the range closes on' do
      pairs = [[root_event(1, 1), holding], [event(2, 5, 2), holding], [event(3, 6, 2), holding]]

      expect(kept(pairs, closing: holding(5))).to eq([1, 2])
      expect(kept(pairs, closing: nil)).to eq([1])
    end

    # Versions 1 and 3 are one transaction, with 2 saved in another meanwhile.
    it 'reads the start and end of the event\'s own transaction' do
      started = [[event(1, 5, 10), holding(5)], [event(2, 6, 20), holding],
                 [event(3, 5, 10), holding], [root_event(4, 30), holding]]
      ended = [[event(1, 6, 10), holding], [event(2, 7, 20), holding],
               [event(3, 8, 10), holding], [root_event(4, 30), holding(6, 8)]]

      expect(kept(started)).to eq([1, 3, 4])
      expect(kept(ended)).to eq([1, 3, 4])
    end

    it 'reads a version saved outside a transaction before and after itself' do
      pairs = [[root_event(1, 1), holding], [event(2, 8, nil), holding],
               [event(3, 9, nil), holding(8)], [root_event(4, 4), holding]]

      expect(kept(pairs)).to eq([1, 2, 4])
    end

    it 'finds a record at any depth below the branch its event came through' do
      reply = record('TrackedReply', 9)
      nested = record('TrackedArticle', 1, comments: collection(record('TrackedComment', 5,
                                                                       replies: collection(reply))))
      other_reply = collection(record('TrackedReply', 10))
      elsewhere = record('TrackedArticle', 1, profile: collection(record('TrackedReply', 9)),
                                              comments: collection(record('TrackedComment', 5,
                                                                          replies: other_reply)))
      pairs = lambda do |snapshot|
        [[root_event(1, 1), snapshot], [event(2, 9, 2, type: 'TrackedReply'), snapshot]]
      end

      expect(kept(pairs.call(nested), closing: nested)).to eq([1, 2])
      expect(kept(pairs.call(elsewhere), closing: elsewhere)).to eq([1])
    end

    it 'keeps a record found below any of the branches its event came through' do
      snapshot = record('TrackedArticle', 1, comments: collection(record('TrackedComment', 5)),
                                             profile: collection)
      pairs = [[root_event(1, 1), snapshot],
               [event(2, 5, 2, branches: %w[profile comments]), snapshot]]

      expect(kept(pairs, closing: snapshot)).to eq([1, 2])
    end

    # A version names the base class; the snapshot names the record's class.
    it 'finds a record under any class of its base class, but not another type with its ID' do
      document = record('PreparedSpecialDocument', 3)
      special = record('TrackedArticle', 1, comments: collection(document))
      pairs = [[root_event(1, 1), special], [event(2, 3, 2, type: 'PreparedDocument'), special],
               [event(3, 3, 3, type: 'TrackedReply'), special], [root_event(4, 4), special]]

      expect(kept(pairs)).to eq([1, 2, 4])
    end
  end

  # A through's snapshot holds its targets, not the join rows that link them,
  # so a join row's version is never judged by the snapshot.
  it 'keeps the versions of a through\'s join rows' do
    article = TrackedArticle.create!(title: 'Root')
    author = TrackedAuthor.create!(name: 'Author')
    authorship = TrackedAuthorship.create!(article: article, author: author, role: 'writer')
    authorship.update!(role: 'editor')

    steps = PaperTrailDiff.activity_timeline(article, from: first_version(article), to: article,
                                                      associations: [:contributors])

    expect(every_source(steps)).to include(['TrackedAuthorship', authorship.id])
  end
end
