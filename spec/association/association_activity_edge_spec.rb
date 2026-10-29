# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/string_item_database'

ActiveRecord::Schema.define do
  create_table :edge_stickers, force: true do |table|
    table.string :type
    table.string :label, null: false
    table.references :holder, polymorphic: true
    table.integer :sponsor_id
    table.timestamps null: false
  end

  create_table :edge_documents_tags, id: false, force: true do |table|
    table.integer :prepared_document_id, null: false
    table.integer :tracked_tag_id, null: false
  end
end

class EdgeSticker < ActiveRecord::Base
  belongs_to :holder, polymorphic: true, optional: true
  has_paper_trail
end

# An STI subclass that declares its own associations, so the reflection's
# class is not the one PaperTrail names in item_type.
class EdgeSpecialSticker < EdgeSticker
  belongs_to :sponsor, class_name: 'TrackedAuthor', optional: true
end

class EdgeHolder < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  has_many :stickers, class_name: 'EdgeSticker', as: :holder
  has_many :special_stickers, class_name: 'EdgeSpecialSticker', as: :holder
  has_paper_trail
end

class EdgeSpecialDocument < PreparedDocument
  has_many :stickers, class_name: 'EdgeSticker', as: :holder
  has_and_belongs_to_many :tags, class_name: 'TrackedTag', join_table: :edge_documents_tags,
                                 foreign_key: :prepared_document_id,
                                 association_foreign_key: :tracked_tag_id
end

class EdgeHiddenArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  default_scope { where.not(title: 'Hidden') }
  has_and_belongs_to_many :tags, class_name: 'TrackedTag', join_table: :tracked_articles_tags,
                                 foreign_key: :tracked_article_id,
                                 association_foreign_key: :tracked_tag_id
  has_paper_trail
end

RSpec.describe PaperTrailDiff::AssociationActivityEdge do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    StringItemVersionAssociation.delete_all
    StringItemVersion.delete_all
    ActiveRecord::Base.connection.execute('DELETE FROM tracked_articles_tags')
    ActiveRecord::Base.connection.execute('DELETE FROM edge_documents_tags')
    [TrackedReply, TrackedComment, TrackedProfile, TrackedArticle, TrackedAuthor, TrackedTag,
     EdgeSticker, PreparedDocument, StringItemNote, StringItemPost].each(&:delete_all)
  end

  def reflection(model, name)
    model.reflect_on_association(name)
  end

  def window(start)
    PaperTrailDiff::TimeRange.new(start..Time.now.utc)
  end

  def owners(edge, filter)
    edge.relation(filter).distinct.pluck(edge.column).map(&:to_i).sort
  end

  describe 'the base edge' do
    it 'is available for a scalar foreign key only' do
      scalar = described_class.new(reflection(TrackedComment, :article), nil)
      composite = described_class.new(
        instance_double(ActiveRecord::Reflection::BelongsToReflection,
                        foreign_key: Class.new(Array).new(%w[article_id body]),
                        active_record: TrackedComment), nil
      )

      expect(scalar.available?).to be(true)
      expect(composite.available?).to be(false)
    end

    it 'leaves the relation to each kind of edge' do
      edge = described_class.new(reflection(TrackedComment, :article), nil)

      expect { edge.relation([1]) }
        .to raise_error(NotImplementedError,
                        'PaperTrailDiff::AssociationActivityEdge must build its relation')
    end
  end

  describe described_class::Child do
    it 'finds the owners a child belonged to when the window opened or after a change in it' do
      first = TrackedArticle.create!(title: 'From')
      second = TrackedArticle.create!(title: 'To')
      third = TrackedArticle.create!(title: 'Earlier')
      comment = third.comments.create!(body: 'moving')
      comment.update!(article: first)
      start = Time.now.utc
      comment.update!(article: second)
      finish = Time.now.utc
      comment.update!(article: third)
      range = PaperTrailDiff::TimeRange.new(start..finish)
      edge = described_class::Child.new(reflection(TrackedArticle, :comments), range)

      expect(owners(edge, [comment.id])).to eq([first.id, second.id].sort)
      expect(owners(described_class::Child.new(reflection(TrackedArticle, :comments), nil),
                    [comment.id])).to eq([first.id, second.id, third.id].sort)
    end

    it 'reads only its own child model and foreign key' do
      article = TrackedArticle.create!(title: 'Owner')
      author = TrackedAuthor.create!(id: 700, name: 'Reviewer')
      comment = article.comments.create!(id: 800, body: 'one', reviewer: author)
      TrackedComment.create!(id: 801, article: TrackedArticle.create!(id: 800, title: 'Same id'),
                             body: 'other')
      reply = comment.replies.create!(id: 801, body: 'reply')
      articles = described_class::Child.new(reflection(TrackedArticle, :comments), nil)
      reviewed = described_class::Child.new(reflection(TrackedAuthor, :reviewed_comments), nil)

      expect(owners(articles, [comment.id])).to eq([article.id])
      expect(owners(articles, [reply.id])).to eq([800])
      expect(owners(reviewed, [comment.id])).to eq([author.id])
    end

    # A profile shares the comment's id and key name; the comment's key under
    # another name still names an article.
    it 'reads only rows of its child model under its key name' do
      article = TrackedArticle.create!(title: 'Owner')
      comment = article.comments.create!(body: 'one')
      TrackedProfile.create!(id: comment.id, article: TrackedArticle.create!(title: 'Profiled'),
                             bio: 'same id')
      other = TrackedArticle.create!(title: 'Other key')
      PaperTrail::VersionAssociation.create!(
        version_id: comment.versions.reorder(:id).last.id, foreign_key_name: 'source_article_id',
        foreign_key_id: other.id, foreign_type: 'TrackedArticle'
      )
      edge = described_class::Child.new(reflection(TrackedArticle, :comments), nil)

      expect(owners(edge, [comment.id])).to eq([article.id])
    end

    it 'takes a subquery as readily as an array, and types both columns' do
      article = TrackedArticle.create!(title: 'Owner')
      comment = article.comments.create!(body: 'one')
      edge = described_class::Child.new(reflection(TrackedArticle, :comments), nil)
      string_edge = described_class::Child.new(reflection(StringItemPost, :notes), nil)

      expect(owners(edge, TrackedComment.where(id: comment.id).select(:id))).to eq([article.id])
      expect([edge.type, edge.filter_type]).to eq(%i[integer integer])
      expect([string_edge.type, string_edge.filter_type]).to eq(%i[integer string])
      expect(edge.column).to eq(PaperTrail::VersionAssociation.arel_table[:foreign_key_id])
    end

    it 'accepts the owner types PT-AT may record for a polymorphic key, and no other' do
      holder = EdgeHolder.create!(title: 'Holder')
      sticker = EdgeSticker.create!(label: 'one', holder: holder)
      edge = described_class::Child.new(reflection(EdgeHolder, :stickers), nil)
      rows = PaperTrail::VersionAssociation.where(foreign_key_name: 'holder_id')

      expect(owners(edge, [sticker.id])).to eq([holder.id])
      ['', nil].each do |type|
        rows.update_all(foreign_type: type)
        expect(owners(edge, [sticker.id])).to eq([holder.id])
      end
      rows.update_all(foreign_type: 'TrackedAuthor')
      expect(owners(edge, [sticker.id])).to eq([])
    end

    it 'accepts both an STI owner name and its base class name' do
      document = EdgeSpecialDocument.create!(name: 'Holder')
      sticker = EdgeSticker.create!(label: 'one', holder: document)
      edge = described_class::Child.new(reflection(EdgeSpecialDocument, :stickers), nil)
      rows = PaperTrail::VersionAssociation.where(foreign_key_name: 'holder_id')

      %w[EdgeSpecialDocument PreparedDocument].each do |type|
        rows.update_all(foreign_type: type)
        expect(owners(edge, [sticker.id])).to eq([document.id])
      end
    end

    it 'reads an STI child under its base class name' do
      holder = EdgeHolder.create!(title: 'Holder')
      sticker = EdgeSpecialSticker.create!(label: 'special', holder: holder)
      edge = described_class::Child.new(reflection(EdgeHolder, :special_stickers), nil)

      expect(owners(edge, [sticker.id])).to eq([holder.id])
    end
  end

  describe described_class::BelongsTo do
    it 'finds the owners that pointed at a target when the window opened or after' do
      author = TrackedAuthor.create!(name: 'Ann')
      kept = TrackedArticle.create!(title: 'Kept', author: author)
      left = TrackedArticle.create!(title: 'Left', author: author)
      earlier = TrackedArticle.create!(title: 'Earlier', author: author)
      earlier.update!(author: nil)
      start = Time.now.utc
      left.update!(author: TrackedAuthor.create!(name: 'Bea'))
      finish = Time.now.utc
      TrackedArticle.create!(title: 'After', author: author)
      edge = described_class::BelongsTo.new(reflection(TrackedArticle, :author),
                                            PaperTrailDiff::TimeRange.new(start..finish))

      expect(owners(edge, [author.id])).to eq([kept.id, left.id].sort)
      expect([edge.type, edge.filter_type]).to eq(%i[integer integer])
      expect(edge.column).to eq(PaperTrail::Version.arel_table[:item_id])
    end

    it 'reads only its own owner model and foreign key' do
      author = TrackedAuthor.create!(id: 600, name: 'Ann')
      article = TrackedArticle.create!(id: 610, title: 'Owner', author: author)
      TrackedComment.create!(id: 620, article: TrackedArticle.create!(id: 600, title: 'Target'),
                             body: 'same key name, other model', reviewer: author)
      TrackedComment.create!(id: 630, article: TrackedArticle.find(600), body: 'not reviewed',
                             reviewer: TrackedAuthor.create!(name: 'Other'))
      edge = described_class::BelongsTo.new(reflection(TrackedArticle, :author), nil)
      reviewers = described_class::BelongsTo.new(reflection(TrackedComment, :reviewer), nil)

      expect(owners(edge, [600])).to eq([article.id])
      expect(owners(reviewers, [600])).to eq([620])
    end

    it 'reads only owners of its own model under a shared key name' do
      article = TrackedArticle.create!(title: 'Target')
      comment = article.comments.create!(body: 'owner')
      TrackedProfile.create!(article: article, bio: 'also points at it')
      edge = described_class::BelongsTo.new(reflection(TrackedComment, :article), nil)

      expect(owners(edge, [article.id])).to eq([comment.id])
    end

    it 'reads an STI owner under its base class name' do
      author = TrackedAuthor.create!(name: 'Sponsor')
      sticker = EdgeSpecialSticker.create!(label: 'sponsored', sponsor: author)
      edge = described_class::BelongsTo.new(reflection(EdgeSpecialSticker, :sponsor), nil)

      expect(owners(edge, [author.id])).to eq([sticker.id])
    end

    it 'names the target types of a polymorphic key and narrows to one' do
      article = TrackedArticle.create!(id: 500, title: 'Article holder')
      author = TrackedAuthor.create!(id: 500, name: 'Author holder')
      on_article = EdgeSticker.create!(label: 'a', holder: article)
      EdgeSticker.create!(label: 'a again', holder: article)
      on_author = EdgeSticker.create!(label: 'b', holder: author)
      typeless = EdgeSticker.create!(label: 'typeless', holder: article)
      PaperTrail::VersionAssociation.joins(:version)
                                    .where(versions: { item_type: 'EdgeSticker',
                                                       item_id: typeless.id })
                                    .update_all(foreign_type: nil)
      EdgeSticker.create!(label: 'loose')
      polymorphic = reflection(EdgeSticker, :holder)
      start = Time.now.utc
      later = EdgeSticker.create!(label: 'late', holder: TrackedTag.create!(name: 'tag'))
      edge = described_class::BelongsTo.new(polymorphic, nil)
      windowed = described_class::BelongsTo.new(polymorphic, window(start))

      expect(edge.target_types).to contain_exactly('TrackedArticle', 'TrackedAuthor', 'TrackedTag')
      expect(windowed.target_types).to contain_exactly('TrackedArticle', 'TrackedAuthor',
                                                       'TrackedTag')
      expect(owners(edge, [500])).to include(on_article.id, on_author.id)
      expect(owners(described_class::BelongsTo.new(polymorphic, nil, foreign_type: 'TrackedAuthor'),
                    [500]))
        .to eq([on_author.id])
      expect(later.id).to be > on_author.id
    end

    it 'leaves out target types recorded only before the window' do
      article = TrackedArticle.create!(title: 'Old holder')
      sticker = EdgeSticker.create!(label: 'moving', holder: article)
      sticker.update!(holder: TrackedAuthor.create!(name: 'New holder'))
      start = Time.now.utc
      EdgeSticker.create!(label: 'untouched')
      edge = described_class::BelongsTo.new(reflection(EdgeSticker, :holder), window(start))

      expect(edge.target_types).to eq(['TrackedAuthor'])
    end
  end

  describe described_class::LiveHabtm do
    it 'finds the owners a join row links a target to now' do
      tag = TrackedTag.create!(name: 'ruby')
      tagged = TrackedArticle.create!(title: 'Tagged')
      tagged.tags << tag
      TrackedArticle.create!(title: 'Other').tags << TrackedTag.create!(name: 'rails')
      edge = described_class::LiveHabtm.new(reflection(TrackedArticle, :tags), nil)

      expect(edge.available?).to be(true)
      expect(owners(edge, [tag.id])).to eq([tagged.id])
      expect(owners(edge, TrackedTag.where(id: tag.id).select(:id))).to eq([tagged.id])
      expect([edge.type, edge.filter_type]).to eq(%i[integer integer])
      expect(edge.column.to_s).to eq('"tracked_articles_tags"."tracked_article_id"')
    end

    it 'reads the join table past the owner default scope and STI condition' do
      tag = TrackedTag.create!(name: 'ruby')
      hidden = EdgeHiddenArticle.create!(title: 'Hidden')
      hidden.tags << tag
      document = EdgeSpecialDocument.create!(name: 'Tagged')
      document.tags << tag
      articles = described_class::LiveHabtm.new(reflection(EdgeHiddenArticle, :tags), nil)
      documents = described_class::LiveHabtm.new(reflection(EdgeSpecialDocument, :tags), nil)

      expect(owners(articles, [tag.id])).to eq([hidden.id])
      expect(owners(documents, [tag.id])).to eq([document.id])
    end
  end

  describe described_class::RecordedHabtm do
    # PT-AT records HABTM membership on a version saved from a fresh record.
    def tag_with_version(article, tag)
      article.tags << tag
      TrackedArticle.transaction { TrackedArticle.find(article.id).paper_trail.save_with_version }
    end

    it 'finds owners whose versions recorded the target, from the window start on' do
      tag = TrackedTag.create!(name: 'ruby')
      before = TrackedArticle.create!(title: 'Before')
      tag_with_version(before, tag)
      start = Time.now.utc
      inside = TrackedArticle.create!(title: 'Inside')
      tag_with_version(inside, tag)
      tag_with_version(TrackedArticle.create!(title: 'Other'), TrackedTag.create!(name: 'rails'))
      tags = reflection(TrackedArticle, :tags)

      edge = described_class::RecordedHabtm.new(tags, nil)
      expect(edge.available?).to be(true)
      expect([edge.type, edge.filter_type]).to eq(%i[integer integer])
      expect(edge.column).to eq(PaperTrail::Version.arel_table[:item_id])
      expect(owners(described_class::RecordedHabtm.new(tags, window(start)), [tag.id]))
        .to eq([inside.id])
      expect(owners(described_class::RecordedHabtm.new(tags, nil), [tag.id]))
        .to eq([before.id, inside.id].sort)
    end

    it 'reads only its own association name and owner model' do
      tag = TrackedTag.create!(name: 'ruby')
      article = TrackedArticle.create!(title: 'Labelled')
      version = article.versions.reorder(:id).last
      PaperTrail::VersionAssociation.create!(version_id: version.transaction_id,
                                             foreign_key_name: 'labels', foreign_key_id: tag.id)
      document = EdgeSpecialDocument.create!(name: 'Tagged')
      document.tags << tag
      PreparedDocument.transaction do
        PreparedDocument.find(document.id).paper_trail.save_with_version
      end

      expect(owners(described_class::RecordedHabtm.new(reflection(TrackedArticle, :tags), nil),
                    [tag.id])).to eq([])
      expect(owners(described_class::RecordedHabtm.new(reflection(EdgeSpecialDocument, :tags),
                                                       nil), [tag.id])).to eq([document.id])
    end

    it 'is unavailable when versions have no transaction_id' do
      tags = reflection(TrackedArticle, :tags)
      allow(PaperTrail::Version).to receive(:column_names)
        .and_return(PaperTrail::Version.column_names - ['transaction_id'])

      expect(described_class::RecordedHabtm.new(tags, nil).available?).to be(false)
    end
  end
end
