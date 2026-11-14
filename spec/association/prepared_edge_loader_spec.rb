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

  # Candidates read from the start, as a history reads them, with no end.
  def loader(records, root_versions, start_at: root_versions.first&.created_at)
    described_class.new(records, children: PaperTrailDiff::PreparedChildCandidates.new(start_at))
  end

  def load_edge(owner_class, owner_ids, association, root_versions, **options)
    start_at = options.fetch(:start_at, root_versions.first&.created_at)
    records = index(start_at, [owner_class, owner_ids])
    loader(records, root_versions, start_at: start_at)
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

      groups = load_edge(TrackedArticle, [article.id], :author, versions)

      expect(groups).to eq('TrackedAuthor' => { model: TrackedAuthor, ids: [first.id, second.id] })
    end

    it 'reads a plain key without building a record for each state' do
      article = TrackedArticle.create!(title: 'Owner', author: TrackedAuthor.create!(name: 'Ann'))
      versions = versions_of(article)
      records = index(versions.first.created_at, [TrackedArticle, [article.id]])
      expect_any_instance_of(PaperTrailDiff::PreparedRecordState).not_to receive(:instantiate)

      groups = loader(records, versions).call(TrackedArticle, [article.id],
                                              TrackedArticle.reflect_on_association(:author))

      expect(groups.fetch('TrackedAuthor').fetch(:ids)).to eq([article.author_id])
    end

    it 'returns no group when no owner pointed at a target' do
      article = TrackedArticle.create!(title: 'Alone')

      expect(load_edge(TrackedArticle, [article.id], :author, versions_of(article)))
        .to eq({})
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

      groups = load_edge(EdgeLoaderBadge, ids, :holder, versions)

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

      groups = load_edge(TrackedArticle, [article.id], :comments, versions,
                         start_at: start_at)

      expect(groups).to eq('TrackedComment' => {
                             model: TrackedComment, ids: [kept.id, moved.id, live.id],
                             owners: { article.id.to_s => [kept.id, moved.id, live.id] }
                           })
    end

    it 'keeps owners apart and lists a child once per owner' do
      first = TrackedArticle.create!(title: 'First')
      second = TrackedArticle.create!(title: 'Second')
      comment = first.comments.create!(body: 'one')
      comment.update!(body: 'two')
      other = second.comments.create!(body: 'other')

      groups = load_edge(TrackedArticle, [first.id, second.id], :comments,
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

      groups = load_edge(TrackedArticle, [article.id], :comments, versions_of(article),
                         start_at: Time.now.utc - 60)

      expect(groups).to eq({})
    end

    it 'reads an STI child under its base class name, and its siblings live' do
      article = EdgeLoaderArticle.create!(title: 'Holder')
      pinned = EdgeLoaderPinnedBadge.create!(label: 'pinned', holder: article)
      plain = EdgeLoaderBadge.create!(label: 'plain', holder: article)
      PaperTrail::Version.where(item_type: 'EdgeLoaderBadge').delete_all

      groups = load_edge(EdgeLoaderArticle, [article.id], :pinned_badges, versions_of(article),
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

      groups = load_edge(EdgeLoaderArticle, [article.id], :visible_badges, versions_of(article),
                         start_at: Time.now.utc - 60)

      expect(groups.fetch('EdgeLoaderVisibleBadge').fetch(:ids)).to eq([hidden.id])
    end

    it 'reads live polymorphic children of the owner type only' do
      article = EdgeLoaderArticle.create!(id: 210, title: 'Holder')
      mine = EdgeLoaderBadge.create!(label: 'mine', holder: article)
      EdgeLoaderBadge.create!(label: 'other', holder: TrackedAuthor.create!(id: 210, name: 'A'))
      PaperTrail::Version.where(item_type: 'EdgeLoaderBadge').delete_all

      groups = load_edge(EdgeLoaderArticle, [article.id], :badges, versions_of(article),
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

      groups = load_edge(EdgeLoaderDocument, [document.id], :badges,
                         document.versions.reorder(:id).to_a, start_at: Time.now.utc - 60)

      expect(groups.fetch('EdgeLoaderBadge').fetch(:ids))
        .to contain_exactly(*badges.map(&:id), live_only.id)
    end

    it 'types child ids read from a string item_id' do
      post = StringItemPost.create!(title: 'Post')
      note = post.notes.create!(body: 'one')
      StringItemNote.where(id: note.id).delete_all

      groups = load_edge(StringItemPost, [post.id], :notes, post.versions.to_a,
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

      groups = load_edge(EdgeLoaderArticle, [article.id], :badges, versions_of(article),
                         start_at: Time.now.utc - 60)

      expect(groups.fetch('EdgeLoaderBadge').fetch(:ids))
        .to contain_exactly(recorded.id, untyped.id, blank.id)
    end
  end
end
