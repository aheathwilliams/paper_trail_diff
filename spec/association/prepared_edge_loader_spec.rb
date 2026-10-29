# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/string_item_database'

ActiveRecord::Schema.define do
  create_table :edge_loader_badges, force: true do |table|
    table.string :type
    table.string :label, null: false
    table.references :holder, polymorphic: true
    table.timestamps null: false
  end
end

class EdgeLoaderBadge < ActiveRecord::Base
  belongs_to :holder, polymorphic: true, optional: true
  has_paper_trail
end

class EdgeLoaderPinnedBadge < EdgeLoaderBadge
end

# The same table without STI, hiding some badges behind a default scope.
class EdgeLoaderVisibleBadge < ActiveRecord::Base
  self.table_name = 'edge_loader_badges'
  self.inheritance_column = :_no_sti
  default_scope { where.not(label: 'hidden') }
  belongs_to :holder, polymorphic: true, optional: true
  has_paper_trail
end

class EdgeLoaderArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  has_many :badges, class_name: 'EdgeLoaderBadge', as: :holder
  has_many :pinned_badges, class_name: 'EdgeLoaderPinnedBadge', as: :holder
  has_many :visible_badges, class_name: 'EdgeLoaderVisibleBadge', as: :holder
  has_paper_trail
end

class EdgeLoaderDocument < PreparedDocument
  has_many :badges, class_name: 'EdgeLoaderBadge', as: :holder
end

RSpec.describe PaperTrailDiff::PreparedEdgeLoader do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    StringItemVersionAssociation.delete_all
    StringItemVersion.delete_all
    ActiveRecord::Base.connection.execute('DELETE FROM tracked_articles_tags')
    [TrackedProfile, TrackedComment, TrackedArticle, TrackedAuthor, TrackedTag, EdgeLoaderBadge,
     PreparedDocument, StringItemNote, StringItemPost].each(&:delete_all)
  end

  def versions_of(record)
    record.versions.reorder(:created_at, :id).to_a
  end

  def index(start_at, *loaded)
    records = PaperTrailDiff::PreparedRecordIndex.new(start_at)
    loaded.each { |model, ids| records.load(model, ids) }
    records
  end

  def load_edge(owner_class, owner_ids, association, root_versions, **options)
    start_at = options.fetch(:start_at, root_versions.first&.created_at)
    records = index(start_at, [owner_class, owner_ids])
    described_class.new(records, root_versions, **options)
                   .call(owner_class, owner_ids, owner_class.reflect_on_association(association))
  end

  describe 'belongs_to' do
    it 'groups every target the owners pointed at in the range' do
      first = TrackedAuthor.create!(name: 'Ann')
      second = TrackedAuthor.create!(name: 'Bea')
      article = TrackedArticle.create!(title: 'Moving', author: first)
      versions = versions_of(article)
      article.update!(author: nil)
      article.update!(author: second)
      article.update!(author: first)

      groups, memberships = load_edge(TrackedArticle, [article.id], :author, versions)

      expect(groups).to eq('TrackedAuthor' => { model: TrackedAuthor, ids: [first.id, second.id] })
      expect(memberships).to be_nil
    end

    it 'reads a plain key without building a record for each state' do
      article = TrackedArticle.create!(title: 'Owner', author: TrackedAuthor.create!(name: 'Ann'))
      versions = versions_of(article)
      records = index(versions.first.created_at, [TrackedArticle, [article.id]])
      expect_any_instance_of(PaperTrailDiff::PreparedRecordState).not_to receive(:instantiate)

      groups, = described_class.new(records, versions)
                               .call(TrackedArticle, [article.id],
                                     TrackedArticle.reflect_on_association(:author))

      expect(groups.fetch('TrackedAuthor').fetch(:ids)).to eq([article.author_id])
    end

    it 'returns no group when no owner pointed at a target' do
      article = TrackedArticle.create!(title: 'Alone')

      expect(load_edge(TrackedArticle, [article.id], :author, versions_of(article)))
        .to eq([{}, nil])
    end

    it 'groups a polymorphic key by the class each owner named' do
      article = TrackedArticle.create!(id: 400, title: 'Holder')
      author = TrackedAuthor.create!(id: 400, name: 'Holder')
      badge = EdgeLoaderBadge.create!(label: 'moving', holder: article)
      versions = versions_of(badge)
      badge.update!(holder: author)
      badge.update!(holder: nil)
      badge.update!(holder: article)
      loose = EdgeLoaderBadge.create!(label: 'loose')
      unknown = EdgeLoaderBadge.create!(label: 'unknown', holder: article)
      EdgeLoaderBadge.where(id: unknown.id).update_all(holder_type: 'NoSuchHolder')
      untargeted = EdgeLoaderBadge.create!(label: 'untargeted', holder_type: 'TrackedTag')
      ids = [badge.id, loose.id, unknown.id, untargeted.id]

      groups, = load_edge(EdgeLoaderBadge, ids, :holder, versions)

      expect(groups).to eq(
        'TrackedArticle' => { model: TrackedArticle, ids: [400] },
        'TrackedAuthor' => { model: TrackedAuthor, ids: [400] }
      )
    end
  end

  describe 'has_many and has_one' do
    it 'groups the children each owner held from the range start and now, by owner' do
      article = TrackedArticle.create!(title: 'Owner')
      other = TrackedArticle.create!(title: 'Other')
      gone = article.comments.create!(body: 'left before')
      gone.update!(article: other)
      versions = versions_of(article)
      start_at = Time.now.utc
      kept = article.comments.create!(body: 'kept')
      moved = article.comments.create!(body: 'moved')
      moved.update!(article: other)
      live = article.comments.create!(body: 'live only')
      PaperTrail::Version.where(item_type: 'TrackedComment', item_id: live.id).delete_all

      groups, memberships = load_edge(TrackedArticle, [article.id], :comments, versions,
                                      start_at: start_at)

      expect(groups).to eq('TrackedComment' => {
                             model: TrackedComment, ids: [kept.id, moved.id, live.id],
                             owners: { article.id.to_s => [kept.id, moved.id, live.id] }
                           })
      expect(memberships).to be_nil
    end

    it 'keeps owners apart and lists a child once per owner' do
      first = TrackedArticle.create!(title: 'First')
      second = TrackedArticle.create!(title: 'Second')
      comment = first.comments.create!(body: 'one')
      comment.update!(body: 'two')
      other = second.comments.create!(body: 'other')

      groups, = load_edge(TrackedArticle, [first.id, second.id], :comments,
                          versions_of(first), start_at: Time.now.utc - 60)

      expect(groups.fetch('TrackedComment')).to eq(
        model: TrackedComment, ids: [comment.id, other.id],
        owners: { first.id.to_s => [comment.id], second.id.to_s => [other.id] }
      )
    end

    # A comment reviewed by author 300, a profile of article 300, and a row
    # renamed to another key of the same type all record the key 300.
    it 'reads only children of the reflected model under its own key' do
      article = TrackedArticle.create!(id: 300, title: 'Owner')
      author = TrackedAuthor.create!(id: 300, name: 'Reviewer')
      TrackedComment.create!(article: TrackedArticle.create!(title: 'Elsewhere'),
                             body: 'reviewed', reviewer: author)
      TrackedProfile.create!(id: 9_300, article: article, bio: 'not a comment')
      renamed = TrackedComment.create!(article: article, body: 'renamed key')
      PaperTrail::VersionAssociation.joins(:version)
                                    .where(versions: { item_type: 'TrackedComment',
                                                       item_id: renamed.id })
                                    .update_all(foreign_key_name: 'source_article_id')
      TrackedComment.where(id: renamed.id).delete_all

      groups, = load_edge(TrackedArticle, [article.id], :comments, versions_of(article),
                          start_at: Time.now.utc - 60)

      expect(groups).to eq({})
    end

    it 'reads an STI child under its base class name, and its siblings live' do
      article = EdgeLoaderArticle.create!(title: 'Holder')
      pinned = EdgeLoaderPinnedBadge.create!(label: 'pinned', holder: article)
      plain = EdgeLoaderBadge.create!(label: 'plain', holder: article)
      PaperTrail::Version.where(item_type: 'EdgeLoaderBadge').delete_all

      groups, = load_edge(EdgeLoaderArticle, [article.id], :pinned_badges, versions_of(article),
                          start_at: Time.now.utc - 60)
      pinned.update!(label: 'pinned again')
      EdgeLoaderPinnedBadge.where(id: pinned.id).delete_all
      historical, = load_edge(EdgeLoaderArticle, [article.id], :pinned_badges,
                              versions_of(article), start_at: Time.now.utc - 60)

      expect(groups.fetch('EdgeLoaderPinnedBadge').fetch(:ids)).to eq([pinned.id, plain.id])
      expect(historical.fetch('EdgeLoaderPinnedBadge').fetch(:ids)).to eq([pinned.id, plain.id])
    end

    it 'reads live children hidden by their default scope' do
      article = EdgeLoaderArticle.create!(title: 'Holder')
      hidden = EdgeLoaderVisibleBadge.create!(label: 'hidden', holder: article)
      PaperTrail::Version.where(item_type: 'EdgeLoaderVisibleBadge').delete_all

      groups, = load_edge(EdgeLoaderArticle, [article.id], :visible_badges, versions_of(article),
                          start_at: Time.now.utc - 60)

      expect(groups.fetch('EdgeLoaderVisibleBadge').fetch(:ids)).to eq([hidden.id])
    end

    it 'reads live polymorphic children of the owner type only' do
      article = EdgeLoaderArticle.create!(id: 210, title: 'Holder')
      mine = EdgeLoaderBadge.create!(label: 'mine', holder: article)
      EdgeLoaderBadge.create!(label: 'other', holder: TrackedAuthor.create!(id: 210, name: 'A'))
      PaperTrail::Version.where(item_type: 'EdgeLoaderBadge').delete_all

      groups, = load_edge(EdgeLoaderArticle, [article.id], :badges, versions_of(article),
                          start_at: Time.now.utc - 60)

      expect(groups.fetch('EdgeLoaderBadge').fetch(:ids)).to eq([mine.id])
    end

    it 'accepts an STI owner by its own or its base class name' do
      document = EdgeLoaderDocument.create!(name: 'Holder')
      badges = %w[EdgeLoaderDocument PreparedDocument].map do |type|
        badge = EdgeLoaderBadge.create!(label: type, holder: document)
        PaperTrail::VersionAssociation.joins(:version)
                                      .where(versions: { item_type: 'EdgeLoaderBadge',
                                                         item_id: badge.id })
                                      .update_all(foreign_type: type)
        badge
      end
      EdgeLoaderBadge.where(id: badges.first.id).delete_all
      live_only = EdgeLoaderBadge.create!(label: 'live', holder: document)
      PaperTrail::Version.where(item_type: 'EdgeLoaderBadge', item_id: live_only.id).delete_all

      groups, = load_edge(EdgeLoaderDocument, [document.id], :badges,
                          document.versions.reorder(:id).to_a, start_at: Time.now.utc - 60)

      expect(groups.fetch('EdgeLoaderBadge').fetch(:ids))
        .to contain_exactly(*badges.map(&:id), live_only.id)
    end

    it 'types child ids read from a string item_id' do
      post = StringItemPost.create!(title: 'Post')
      note = post.notes.create!(body: 'one')
      StringItemNote.where(id: note.id).delete_all

      groups, = load_edge(StringItemPost, [post.id], :notes, post.versions.to_a,
                          start_at: Time.now.utc - 60)

      expect(groups).to eq('StringItemNote' => {
                             model: StringItemNote, ids: [note.id],
                             owners: { post.id.to_s => [note.id] }
                           })
    end

    it 'reads polymorphic children recorded under any form of the owner type, live by type' do
      article = EdgeLoaderArticle.create!(id: 200, title: 'Holder')
      author = TrackedAuthor.create!(id: 200, name: 'Same id')
      recorded = EdgeLoaderBadge.create!(label: 'recorded', holder: article)
      EdgeLoaderBadge.create!(label: 'other holder', holder: author)
      PaperTrail::VersionAssociation.where(foreign_key_name: 'holder_id',
                                           foreign_key_id: author.id,
                                           foreign_type: 'TrackedAuthor')
                                    .update_all(foreign_type: 'Unrelated')
      untyped = EdgeLoaderBadge.create!(label: 'untyped', holder: article)
      PaperTrail::VersionAssociation.joins(:version)
                                    .where(versions: { item_id: untyped.id })
                                    .update_all(foreign_type: nil)
      EdgeLoaderBadge.where(id: untyped.id).delete_all
      blank = EdgeLoaderBadge.create!(label: 'blank', holder: article)
      PaperTrail::VersionAssociation.joins(:version)
                                    .where(versions: { item_id: blank.id })
                                    .update_all(foreign_type: '')
      EdgeLoaderBadge.where(id: blank.id).delete_all

      groups, = load_edge(EdgeLoaderArticle, [article.id], :badges, versions_of(article),
                          start_at: Time.now.utc - 60)

      expect(groups.fetch('EdgeLoaderBadge').fetch(:ids))
        .to contain_exactly(recorded.id, untyped.id, blank.id)
    end
  end

  describe 'has_and_belongs_to_many' do
    def tag_version(article, *tags)
      article.tags << tags
      TrackedArticle.transaction { TrackedArticle.find(article.id).paper_trail.save_with_version }
      versions_of(article).last
    end

    it 'groups the tags recorded in the root transactions and keys membership by transaction' do
      article = TrackedArticle.create!(title: 'Tagged')
      ruby = TrackedTag.create!(name: 'ruby')
      rails = TrackedTag.create!(name: 'rails')
      first = tag_version(article, ruby)
      second = tag_version(article, rails)
      ignored = tag_version(TrackedArticle.create!(title: 'Other'), TrackedTag.create!(name: 'x'))
      untracked = versions_of(article).first
      PaperTrail::VersionAssociation.create!(version_id: second.transaction_id,
                                             foreign_key_name: 'labels', foreign_key_id: 9_999)

      groups, memberships = load_edge(TrackedArticle, [article.id], :tags,
                                      [untracked, first, second].sort_by(&:created_at))

      expect(groups).to eq('TrackedTag' => { model: TrackedTag, ids: [ruby.id, rails.id] })
      expect(memberships).to eq(
        untracked.transaction_id.to_s => [],
        first.transaction_id.to_s => [ruby.id],
        second.transaction_id.to_s => [ruby.id, rails.id]
      )
      expect(ignored.transaction_id).not_to eq(second.transaction_id)
    end

    it 'skips root versions saved outside a transaction' do
      article = TrackedArticle.create!(title: 'Tagged')
      version = tag_version(article, TrackedTag.create!(name: 'ruby'))
      allow(version).to receive(:transaction_id).and_return(nil)

      expect(load_edge(TrackedArticle, [article.id], :tags, [version])).to eq([{}, {}])
    end
  end

  it 'reads nothing for a composite foreign key' do
    reflection = instance_double(ActiveRecord::Reflection::HasManyReflection,
                                 macro: :has_many,
                                 foreign_key: Class.new(Array).new(%w[article_id body]))
    article = TrackedArticle.create!(title: 'Owner')
    loader = described_class.new(index(nil), versions_of(article))

    expect(loader.call(TrackedArticle, [article.id], reflection)).to eq([{}, nil])
    allow(reflection).to receive(:macro).and_return(:belongs_to)
    expect(loader.call(TrackedArticle, [article.id], reflection)).to eq([{}, nil])
  end

  it 'starts at the first root version unless told otherwise' do
    article = TrackedArticle.create!(title: 'Owner')
    gone = article.comments.create!(body: 'gone before')
    gone.update!(article: TrackedArticle.create!(title: 'Other'))
    versions = [article.paper_trail.save_with_version && versions_of(article).last]

    defaulted, = described_class.new(index(nil), versions)
                                .call(TrackedArticle, [article.id],
                                      TrackedArticle.reflect_on_association(:comments))
    unbounded, = described_class.new(index(nil), [])
                                .call(TrackedArticle, [article.id],
                                      TrackedArticle.reflect_on_association(:comments))

    expect(defaulted).to eq({})
    expect(unbounded.fetch('TrackedComment').fetch(:ids)).to eq([gone.id])
  end
end
