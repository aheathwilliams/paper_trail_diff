# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/string_item_database'

ActiveRecord::Schema.define do
  create_table :child_loader_badges, force: true do |table|
    table.string :type
    table.string :label, null: false
    table.references :holder, polymorphic: true
    table.integer :sponsor_id
    table.timestamps null: false
  end
end

class ChildLoaderBadge < ActiveRecord::Base
  belongs_to :holder, polymorphic: true, optional: true
  # Another key to the same owners, which does not make a badge theirs.
  belongs_to :sponsor, class_name: 'PreparedDocument', optional: true
  has_paper_trail
end

class ChildLoaderPinnedBadge < ChildLoaderBadge
end

# The same table without STI, hiding some badges behind a default scope.
class ChildLoaderVisibleBadge < ActiveRecord::Base
  self.table_name = 'child_loader_badges'
  self.inheritance_column = :_no_sti
  default_scope { where.not(label: 'hidden') }
  belongs_to :holder, polymorphic: true, optional: true
  has_paper_trail
end

# A subclass owner: a polymorphic key names its base class, PreparedDocument.
class ChildLoaderDocument < PreparedDocument
  has_many :badges, class_name: 'ChildLoaderBadge', as: :holder
  has_many :pinned_badges, class_name: 'ChildLoaderPinnedBadge', as: :holder
  has_many :visible_badges, class_name: 'ChildLoaderVisibleBadge', as: :holder
end

RSpec.describe PaperTrailDiff::ActivityChildCandidateLoader do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    StringItemVersionAssociation.delete_all
    StringItemVersion.delete_all
    [ChildLoaderBadge, PreparedDocument, TrackedComment, TrackedArticle, TrackedAuthor,
     StringItemNote, StringItemPost].each(&:delete_all)
  end

  def loader(owner_class, owner_ids, association, start_at = nil, end_at = nil)
    described_class.new(owner_class, owner_ids, owner_class.reflect_on_association(association),
                        start_at, end_at)
  end

  # A time between the versions saved before it and those saved after.
  def marker
    TrackedAuthor.create!(name: 'Marker').versions.last.created_at
  end

  # The child ids of the rows, which are owner id, child id, time and event.
  def child_ids(owner_class, owner_ids, association)
    loader(owner_class, owner_ids, association).historical_rows.map { |row| row.fetch(1) }
  end

  def document(name = 'Board')
    ChildLoaderDocument.create!(name: name)
  end

  # PT-AT records a version's foreign keys after its change, so the latest
  # version before the start names the owner the child had at the start.
  it 'reads the version each child had at the start and every version after it' do
    board = document
    badge = ChildLoaderBadge.create!(label: 'Draft', holder: board)
    badge.update!(label: 'Kept')
    start = TrackedAuthor.create!(name: 'Marker').versions.last.created_at
    badge.update!(label: 'Final')
    kept, final = badge.versions.reorder(:id).last(2)

    expect(loader(ChildLoaderDocument, [board.id], :badges, start).historical_rows)
      .to contain_exactly([board.id, badge.id, kept.created_at, 'update'],
                          [board.id, badge.id, final.created_at, 'update'])
  end

  it "reads only the given owners' children, under the association's own key" do
    board, other = %w[Board Other].map { |name| document(name) }
    held = ChildLoaderBadge.create!(label: 'Held', holder: board)
    ChildLoaderBadge.create!(label: 'Elsewhere', holder: other)
    ChildLoaderBadge.create!(label: 'Sponsored', holder: other, sponsor: board)

    expect(child_ids(ChildLoaderDocument, [board.id], :badges)).to eq([held.id])
  end

  # A polymorphic key names the base class, and a plain belongs_to the class
  # it names, which may be the subclass. A row with no type is anyone's.
  it 'reads rows recorded under any name the owner goes by, or none' do
    board = document
    badges = %w[base own untyped blank foreign].to_h do |label|
      [label, ChildLoaderBadge.create!(label: label, holder: board)]
    end
    { 'own' => 'ChildLoaderDocument', 'untyped' => nil, 'blank' => '',
      'foreign' => 'TrackedArticle' }.each do |label, type|
      PaperTrail::VersionAssociation.joins(:version)
                                    .where(versions: { item_type: 'ChildLoaderBadge',
                                                       item_id: badges.fetch(label).id })
                                    .update_all(foreign_type: type)
    end

    expect(child_ids(ChildLoaderDocument, [board.id], :badges))
      .to match_array(badges.values_at('base', 'own', 'untyped', 'blank').map(&:id))
  end

  # A record can change type, so a plain badge may have been pinned within
  # the range; a model that only shares the table is not a badge.
  it "reads every version of the association's base class, which its subclass's carry" do
    board = document
    pinned = ChildLoaderPinnedBadge.create!(label: 'Pinned', holder: board)
    plain = ChildLoaderBadge.create!(label: 'Plain', holder: board)
    ChildLoaderVisibleBadge.create!(label: 'Another model', holder: board)

    expect(child_ids(ChildLoaderDocument, [board.id], :pinned_badges))
      .to contain_exactly(pinned.id, plain.id)
  end

  it "reads a child id stored as a string as the child key's type" do
    post = StringItemPost.create!(title: 'Post')
    note = post.notes.create!(body: 'Note')

    expect(child_ids(StringItemPost, [post.id], :notes)).to eq([note.id])
  end

  it 'reads the live children of the given owners, past the default scope, by owner type' do
    board, other = %w[Board Other].map { |name| document(name) }
    shown = ChildLoaderVisibleBadge.create!(label: 'shown', holder: board)
    hidden = ChildLoaderVisibleBadge.create!(label: 'hidden', holder: board)
    ChildLoaderVisibleBadge.create!(label: 'elsewhere', holder: other)
    ChildLoaderVisibleBadge.create!(label: 'same id', holder_type: 'TrackedArticle',
                                    holder_id: board.id)

    expect(loader(ChildLoaderDocument, [board.id], :visible_badges).current_pairs)
      .to contain_exactly([board.id, shown.id], [board.id, hidden.id])
  end

  it "reads the live rows of the association's base class, as history does" do
    board = document
    pinned = ChildLoaderPinnedBadge.create!(label: 'Pinned', holder: board)
    plain = ChildLoaderBadge.create!(label: 'Plain', holder: board)

    expect(loader(ChildLoaderDocument, [board.id], :pinned_badges).current_pairs)
      .to contain_exactly([board.id, pinned.id], [board.id, plain.id])
  end

  it 'reads the live children of a plain has_many' do
    article = TrackedArticle.create!(title: 'Article')
    comment = TrackedComment.create!(article: article, body: 'Comment')
    TrackedComment.create!(article: TrackedArticle.create!(title: 'Other'), body: 'Other')

    expect(loader(TrackedArticle, [article.id], :comments).current_pairs)
      .to eq([[article.id, comment.id]])
  end

  describe 'with an end' do
    # A child created after the end was not there for any state up to it,
    # however many versions it has saved since.
    it 'leaves out a child created after it' do
      article = TrackedArticle.create!(title: 'Article')
      before = article.comments.create!(body: 'Before')
      finish = marker
      before.update!(body: 'Edited after')
      article.comments.create!(body: 'After').update!(body: 'Edited')
      reader = loader(TrackedArticle, [article.id], :comments, nil, finish)

      expect(reader.historical_rows.map { |row| row.values_at(1, 3) })
        .to contain_exactly([before.id, 'create'], [before.id, 'update'])
      expect(reader.current_pairs).to eq([[article.id, before.id]])
    end

    # Its versions say nothing of when it was created, so it may have been
    # there: one whose create was never recorded, or recorded none at all.
    it 'keeps a child no version says was created after it' do
      article = TrackedArticle.create!(title: 'Article')
      finish = marker
      unrecorded = article.comments.create!(body: 'Create not recorded')
      unrecorded.update!(body: 'Edited')
      unrecorded.versions.where(event: 'create').delete_all
      unversioned = PaperTrail.request(enabled: false) { article.comments.create!(body: 'None') }
      reader = loader(TrackedArticle, [article.id], :comments, nil, finish)

      expect(reader.historical_rows.map { |row| row.values_at(1, 3) })
        .to eq([[unrecorded.id, 'update']])
      expect(reader.current_pairs)
        .to contain_exactly([article.id, unrecorded.id], [article.id, unversioned.id])
    end

    # An id used again: the record destroyed after the end was there at it.
    it 'keeps a child created after it under an id that had a version before' do
      article = TrackedArticle.create!(title: 'Article')
      finish = marker
      first = PaperTrail.request(enabled: false) { article.comments.create!(body: 'First') }
      first.destroy!
      again = TrackedComment.create!(id: first.id, article: article, body: 'Again')
      reader = loader(TrackedArticle, [article.id], :comments, nil, finish)

      expect(reader.historical_rows.map { |row| row.fetch(3) }).to include('create')
      expect(reader.current_pairs).to eq([[article.id, again.id]])
    end

    it 'keeps a child created at the end itself' do
      article = TrackedArticle.create!(title: 'Article')
      comment = article.comments.create!(body: 'Comment')
      finish = comment.versions.last.created_at
      reader = loader(TrackedArticle, [article.id], :comments, nil, finish)

      expect(reader.historical_rows.map { |row| row.fetch(1) }).to eq([comment.id])
      expect(reader.current_pairs).to eq([[article.id, comment.id]])
    end

    # Its versions, and those its live row is matched to, name the base class.
    it 'leaves out a child of a subclass created after it' do
      board = document
      kept = board.pinned_badges.create!(label: 'Before')
      finish = marker
      board.pinned_badges.create!(label: 'After')
      reader = loader(ChildLoaderDocument, [board.id], :pinned_badges, nil, finish)

      expect(reader.historical_rows.map { |row| row.fetch(1) }).to eq([kept.id])
      expect(reader.current_pairs).to eq([[board.id, kept.id]])
    end

    # A version's item_id held as a string cannot be compared with an
    # integer key in every database, so the live rows are all read.
    it 'reads every live child where item ids are not held as the child key is' do
      post = StringItemPost.create!(title: 'Post')
      finish = marker
      note = post.notes.create!(body: 'After')
      reader = loader(StringItemPost, [post.id], :notes, nil, finish)

      expect(reader.historical_rows).to eq([])
      expect(reader.current_pairs).to eq([[post.id, note.id]])
    end
  end

  # Without an end no child was created after it, so nothing asks.
  it 'reads without asking when children were created where there is no end' do
    article = TrackedArticle.create!(title: 'Article')
    article.comments.create!(body: 'Comment')
    statements = []
    count = ->(*, payload) { statements << payload[:sql] unless payload[:name] == 'SCHEMA' }
    reader = loader(TrackedArticle, [article.id], :comments)

    ActiveSupport::Notifications.subscribed(count, 'sql.active_record') do
      reader.historical_rows
      reader.current_pairs
    end

    # The rows, the first versions of children made without one, the live rows.
    expect(statements.length).to eq(3)
    expect(statements.grep(/created_versions/)).to eq([])
  end

  it 'reads the owners Support::IDS_PER_STATEMENT to a statement' do
    stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 2)
    articles = Array.new(3) { |index| TrackedArticle.create!(title: "Article #{index}") }
    comments = articles.map { |article| article.comments.create!(body: 'First') }
    statements = []
    count = ->(*, payload) { statements << payload[:sql] unless payload[:name] == 'SCHEMA' }

    rows, pairs = ActiveSupport::Notifications.subscribed(count, 'sql.active_record') do
      reader = loader(TrackedArticle, articles.map(&:id), :comments, Time.now.utc - 3600)
      [reader.historical_rows, reader.current_pairs]
    end

    owned = articles.map(&:id).zip(comments.map(&:id))
    expect(rows.map { |row| row.first(2) }).to match_array(owned)
    expect(pairs).to match_array(owned)
    # Two statements of rows and two of live rows; the first versions of
    # children made without one are read once for every owner.
    expect(statements.length).to eq(5)
  end

  it 'reads nothing for a composite foreign key' do
    article = TrackedArticle.create!(title: 'Article')
    TrackedComment.create!(article: article, body: 'Comment')
    reflection = instance_double(ActiveRecord::Reflection::HasManyReflection,
                                 foreign_key: %w[article_id reviewer_id])
    composite = described_class.new(TrackedArticle, [article.id], reflection, nil)

    expect([composite.historical_rows, composite.current_pairs]).to eq([[], []])
  end

  # PT-AT names only the owner a version saved, so a child made without a
  # version names the owner it had before its first one only in that
  # version's state.
  describe 'a child made without a version' do
    def unversioned(article, body = 'Unversioned')
      PaperTrail.request(enabled: false) { article.comments.create!(body: body) }
    end

    def rows(owner_class, owner_ids, association, start_at = nil)
      loader(owner_class, owner_ids, association, start_at).historical_rows
                                                           .map { |row| row.values_at(0, 1, 3) }
    end

    it 'is under the owner its first version left, once, from the start on' do
      left = TrackedArticle.create!(title: 'Left')
      joined = TrackedArticle.create!(title: 'Joined')
      moved = unversioned(left)
      edited = unversioned(left, 'Edited')
      back = unversioned(left, 'Back')
      start = marker
      moved.update!(article: joined)
      edited.update!(body: 'Edited again')
      back.update!(article: joined)
      back.update!(article: left)

      expect(rows(TrackedArticle, [left.id], :comments, start))
        .to contain_exactly([left.id, moved.id, 'update'], [left.id, edited.id, 'update'],
                            [left.id, back.id, 'update'], [left.id, back.id, 'update'])
      expect(rows(TrackedArticle, [joined.id], :comments))
        .to contain_exactly([joined.id, moved.id, 'update'], [joined.id, back.id, 'update'])
      # Past the move, the comment it moved away is left out; the others'
      # versions before the start name this article.
      expect(rows(TrackedArticle, [left.id], :comments, marker))
        .to contain_exactly([left.id, edited.id, 'update'], [left.id, back.id, 'update'])
    end

    it 'reads nothing from a first version with no state, or none for the key' do
      article = TrackedArticle.create!(title: 'Article')
      other = TrackedArticle.create!(title: 'Other')
      stateless = unversioned(article, 'Stateless')
      keyless = unversioned(article, 'Keyless')
      [stateless, keyless].each { |comment| comment.update!(article: other) }
      stateless.versions.last.update_column(:object, nil)
      version = keyless.versions.last
      version.update_column(:object, version.object.sub(/^article_id: .*\n/, ''))
      PaperTrail::Version.create!(item_type: 'TrackedAuthor', item_id: stateless.id,
                                  event: 'update', object: { 'article_id' => article.id }.to_yaml)

      expect(rows(TrackedArticle, [article.id], :comments)).to eq([])
    end

    it "is under an `as:` owner only where its type names the owner's class" do
      board = document
      away = document('Away')
      badges = [board.class.polymorphic_name, 'TrackedArticle'].map do |type|
        PaperTrail.request(enabled: false) do
          ChildLoaderBadge.create!(label: type, holder_type: type, holder_id: board.id)
        end
      end
      badges.each { |badge| badge.update!(holder: away) }

      expect(rows(ChildLoaderDocument, [board.id], :badges))
        .to eq([[board.id, badges.first.id, 'update']])
    end
  end
end
