# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/string_item_database'
require_relative '../support/source_type_database'

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
  has_many :quiet_stickers, class_name: 'EdgeQuietSticker', as: :holder
  has_paper_trail
end

# Stickers a default scope hides, which an analysis reads all the same.
class EdgeQuietSticker < ActiveRecord::Base
  self.table_name = 'edge_stickers'
  self.inheritance_column = nil
  default_scope { where.not(label: 'hidden') }
  belongs_to :holder, polymorphic: true, optional: true
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
     EdgeSticker, PreparedDocument, StringItemNote, StringItemPost, SourceTypeLink,
     SourceTypeAuthor, SourceTypeTag].each(&:delete_all)
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

  def statements(&)
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    queries
  end

  describe 'the base edge' do
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

  describe described_class::Unversioned do
    def unversioned(&block)
      PaperTrail.request(enabled: false, &block)
    end

    it 'finds the live owners of the children that have no version' do
      article = TrackedArticle.create!(title: 'Owner')
      quiet = unversioned { article.comments.create!(body: 'never versioned') }
      versioned = TrackedArticle.create!(title: 'Other').comments.create!(body: 'versioned')
      edge = described_class::Unversioned.new(reflection(TrackedArticle, :comments), nil)

      expect(owners(edge, [quiet.id, versioned.id])).to eq([article.id])
      expect(owners(edge, TrackedComment.select(:id))).to eq([article.id])
      expect([edge.type, edge.filter_type]).to eq(%i[integer integer])
      expect(edge.column).to eq(TrackedComment.arel_table[:article_id])
    end

    it 'reads only the children in the filter' do
      article = TrackedArticle.create!(title: 'Owner')
      quiet = unversioned { article.comments.create!(body: 'never versioned') }
      unversioned { TrackedArticle.create!(title: 'Other').comments.create!(body: 'not asked') }
      edge = described_class::Unversioned.new(reflection(TrackedArticle, :comments), nil)

      expect(owners(edge, [quiet.id])).to eq([article.id])
      expect(owners(edge, [])).to eq([])
    end

    # The quiet row's key is the versioned row's version id, which only the
    # versioned row's item_id may be told from.
    it 'compares a string item_id with the key as values' do
      post = StringItemPost.create!(title: 'Owner')
      other = StringItemPost.create!(title: 'Other')
      versioned = other.notes.create!(id: 900, body: 'versioned')
      quiet = unversioned do
        post.notes.create!(id: versioned.versions.last.id, body: 'never versioned')
      end
      edge = described_class::Unversioned.new(reflection(StringItemPost, :notes), nil)

      expect(owners(edge, [quiet.id, versioned.id])).to eq([post.id])
      expect(owners(edge, StringItemNote.select(:id))).to eq([post.id])
    end

    # Where the types match, the database compares them in one statement;
    # otherwise the ids of the versioned rows are read first, each once.
    it 'compares the key with item_id in the database only where they share a type' do
      integer_edge = described_class::Unversioned.new(reflection(TrackedArticle, :comments), nil)
      string_edge = described_class::Unversioned.new(reflection(StringItemPost, :notes), nil)
      post = StringItemPost.create!(title: 'Owner')
      2.times { |index| post.notes.first_or_create!(body: 'versioned').update!(body: index.to_s) }

      expect(integer_edge.relation([1]).to_sql).to include('EXISTS')
      sql = statements do
        expect(string_edge.relation(StringItemNote.select(:id)).to_sql).not_to include('EXISTS')
      end
      expect(sql.grep(/DISTINCT/).length).to eq(1)
      expect(sql.grep(/DISTINCT/).first.scan('SELECT').length).to eq(1)
    end

    it 'reads only children held under the polymorphic owner type' do
      holder = EdgeHolder.create!(title: 'Holder')
      document = EdgeSpecialDocument.create!(name: 'Document')
      held = unversioned { EdgeSticker.create!(label: 'held', holder: holder) }
      other = unversioned { EdgeSticker.create!(label: 'other', holder: document) }
      EdgeSticker.where(id: other.id).update_all(holder_id: holder.id)
      edge = described_class::Unversioned.new(reflection(EdgeHolder, :stickers), nil)
      documents = described_class::Unversioned.new(reflection(EdgeSpecialDocument, :stickers), nil)

      expect(owners(edge, [held.id, other.id])).to eq([holder.id])
      expect(owners(documents, [held.id, other.id])).to eq([holder.id])
      expect(owners(edge, [other.id])).to eq([])
      expect(owners(documents, [held.id])).to eq([])
    end

    it 'reads children past their default scope' do
      holder = EdgeHolder.create!(title: 'Holder')
      hidden = unversioned { EdgeQuietSticker.create!(label: 'hidden', holder: holder) }
      edge = described_class::Unversioned.new(reflection(EdgeHolder, :quiet_stickers), nil)

      expect(owners(edge, [hidden.id])).to eq([holder.id])
    end
  end

  describe described_class::UnversionedOwner do
    def unversioned(&block)
      PaperTrail.request(enabled: false, &block)
    end

    it 'finds the owners without versions that point at a target' do
      article = TrackedArticle.create!(title: 'Target')
      quiet = unversioned { article.comments.create!(body: 'never versioned') }
      article.comments.create!(body: 'versioned')
      unversioned { TrackedArticle.create!(title: 'Other').comments.create!(body: 'not asked') }
      edge = described_class::UnversionedOwner.new(reflection(TrackedComment, :article), nil)

      expect(owners(edge, [article.id])).to eq([quiet.id])
      expect(owners(edge, TrackedArticle.where(title: 'Target').select(:id))).to eq([quiet.id])
      expect(owners(edge, [])).to eq([])
      expect([edge.type, edge.filter_type]).to eq(%i[integer integer])
      expect(edge.column).to eq(TrackedComment.arel_table[:id])
    end

    it 'types the filter as the foreign key and the owners as their key' do
      edge = described_class::UnversionedOwner.new(reflection(SourceTypeLink, :origin), nil)
      allow(SourceTypeLink).to receive(:type_for_attribute).and_call_original
      allow(SourceTypeLink).to receive(:type_for_attribute).with('origin_id')
                                                           .and_return(ActiveRecord::Type::String.new)
      typed = described_class::UnversionedOwner.new(reflection(SourceTypeLink, :origin), nil)

      expect([edge.type, edge.filter_type]).to eq(%i[integer integer])
      expect([typed.type, typed.filter_type]).to eq(%i[integer string])
    end

    # The quiet row's key is the versioned row's version id, which only the
    # versioned row's item_id may be told from.
    it 'compares a string item_id with the key as values' do
      post = StringItemPost.create!(title: 'Target')
      versioned = post.notes.create!(id: 900, body: 'versioned')
      quiet = unversioned do
        post.notes.create!(id: versioned.versions.last.id, body: 'never versioned')
      end
      edge = described_class::UnversionedOwner.new(reflection(StringItemNote, :post), nil)

      expect(owners(edge, [post.id])).to eq([quiet.id])
      expect(edge.relation([post.id]).to_sql).not_to include('EXISTS')
    end

    it 'reads an STI owner by the versions of its base class' do
      author = TrackedAuthor.create!(name: 'Sponsor')
      EdgeSpecialSticker.create!(label: 'versioned', sponsor: author)
      quiet = unversioned { EdgeSpecialSticker.create!(label: 'quiet', sponsor: author) }
      edge = described_class::UnversionedOwner.new(reflection(EdgeSpecialSticker, :sponsor), nil)

      expect(owners(edge, [author.id])).to eq([quiet.id])
    end

    it 'names the target types of a polymorphic key and narrows to one' do
      article = TrackedArticle.create!(id: 500, title: 'Article holder')
      author = TrackedAuthor.create!(id: 500, name: 'Author holder')
      on_article = unversioned { EdgeSticker.create!(label: 'a', holder: article) }
      unversioned { EdgeSticker.create!(label: 'a again', holder: article) }
      on_author = unversioned { EdgeSticker.create!(label: 'b', holder: author) }
      unversioned { EdgeSticker.create!(label: 'loose') }
      unversioned { EdgeSticker.create!(label: 'blank', holder_type: '') }
      polymorphic = reflection(EdgeSticker, :holder)
      edge = described_class::UnversionedOwner.new(polymorphic, nil)
      authors = described_class::UnversionedOwner.new(polymorphic, nil,
                                                      foreign_type: 'TrackedAuthor')

      expect(edge.target_types).to contain_exactly('TrackedArticle', 'TrackedAuthor')
      expect(owners(edge, [500])).to include(on_article.id, on_author.id)
      expect(owners(authors, [500])).to eq([on_author.id])
    end

    it 'reads owners past their default scope' do
      holder = EdgeHolder.create!(title: 'Holder')
      hidden = unversioned { EdgeQuietSticker.create!(label: 'hidden', holder: holder) }
      polymorphic = reflection(EdgeQuietSticker, :holder)
      edge = described_class::UnversionedOwner.new(polymorphic, nil, foreign_type: 'EdgeHolder')

      expect(described_class::UnversionedOwner.new(polymorphic, nil).target_types)
        .to eq(['EdgeHolder'])
      expect(owners(edge, [holder.id])).to eq([hidden.id])
    end
  end

  describe described_class::FirstOwnerVersion do
    def unversioned(&block)
      PaperTrail.request(enabled: false, &block)
    end

    def edge_for(start, model = TrackedComment, name = :reviewer, **options)
      described_class::FirstOwnerVersion.new(reflection(model, name), start && window(start),
                                             **options)
    end

    def stored(edge, targets, type = nil)
      edge.stored_owners(type) { targets }.map(&:to_i).sort
    end

    def legacy_comment(reviewer, body)
      article = TrackedArticle.create!(title: 'Article')
      unversioned { article.comments.create!(body: body, reviewer: reviewer) }
    end

    it 'matches in SQL the key a first version kept, and a destroy held' do
      reviewer = TrackedAuthor.create!(name: 'Reviewer')
      kept = legacy_comment(reviewer, 'kept')
      gone = legacy_comment(reviewer, 'gone')
      start = Time.now.utc
      kept.update!(body: 'edited')
      gone.destroy!
      edge = edge_for(start)

      expect(owners(edge, [reviewer.id])).to eq([kept.id, gone.id].sort)
      expect(owners(edge, TrackedAuthor.select(:id))).to eq([kept.id, gone.id].sort)
      expect(stored(edge, [reviewer.id])).to eq([])
      expect([edge.type, edge.filter_type]).to eq(%i[integer integer])
      expect(edge.column).to eq(PaperTrail::Version.arel_table[:item_id])
    end

    it 'reads the stored state of a first version that changed the key' do
      reviewer, other = %w[Reviewer Other].map { |name| TrackedAuthor.create!(name: name) }
      moved = legacy_comment(reviewer, 'moved')
      start = Time.now.utc
      moved.update!(reviewer: other)
      edge = edge_for(start)

      expect(owners(edge, [reviewer.id, other.id])).to eq([])
      expect(stored(edge, [reviewer.id])).to eq([moved.id])
      expect(stored(edge, [other.id])).to eq([])
      later = edge_for(Time.now.utc)
      expect(later.stored_owners { raise 'no version to read' }).to eq([])
    end

    it 'reads a version that recorded no changes in its stored state' do
      reviewer = TrackedAuthor.create!(name: 'Reviewer')
      kept = legacy_comment(reviewer, 'kept')
      start = Time.now.utc
      kept.update!(body: 'edited')
      kept.versions.last.update_column(:object_changes, nil)
      edge = edge_for(start)

      expect(owners(edge, [reviewer.id])).to eq([])
      expect(stored(edge, [reviewer.id])).to eq([kept.id])
    end

    it 'reads no create, no version before the window, and no later version' do
      reviewer = TrackedAuthor.create!(name: 'Reviewer')
      created = TrackedArticle.create!(title: 'A').comments.create!(body: 'c', reviewer: reviewer)
      early = legacy_comment(reviewer, 'early')
      early.update!(body: 'first')
      start = Time.now.utc
      [created, early].each { |comment| comment.update!(body: 'later') }
      edge = edge_for(start)

      expect(owners(edge, [reviewer.id])).to eq([])
      expect(owners(edge_for(nil), [reviewer.id])).to eq([early.id])
      expect(stored(edge, [reviewer.id])).to eq([])
    end

    it 'skips the SQL match and reads every first version for a key PaperTrail does not record' do
      reviewer = TrackedAuthor.create!(name: 'Reviewer')
      kept = legacy_comment(reviewer, 'kept')
      start = Time.now.utc
      kept.update!(body: 'edited')
      allow(PaperTrailDiff::RecordedColumns).to receive(:recorded?).and_return(false)
      edge = edge_for(start)

      expect(owners(edge, [reviewer.id])).to eq([])
      expect(stored(edge, [reviewer.id])).to eq([kept.id])
    end

    it "names a polymorphic key's types and narrows to one" do
      article = TrackedArticle.create!(id: 600, title: 'Article holder')
      author = TrackedAuthor.create!(id: 600, name: 'Author holder')
      kept = unversioned { EdgeSticker.create!(label: 'kept', holder: author) }
      moved = unversioned { EdgeSticker.create!(label: 'moved', holder: article) }
      start = Time.now.utc
      kept.update!(label: 'edited')
      moved.update!(holder: author)
      edge = edge_for(start, EdgeSticker, :holder)
      authors = edge_for(start, EdgeSticker, :holder, foreign_type: 'TrackedAuthor')

      expect(edge.target_types).to contain_exactly('TrackedArticle', 'TrackedAuthor')
      expect(owners(authors, [600])).to eq([kept.id])
      expect(stored(edge, [600], 'TrackedArticle')).to eq([moved.id])
      expect(stored(edge, [600], 'TrackedAuthor')).to eq([])
    end
  end

  describe described_class::FirstVersion do
    def unversioned(&block)
      PaperTrail.request(enabled: false, &block)
    end

    def first_owners(edge, filter)
      edge.owners(filter).map(&:to_i).sort
    end

    # A child's first version that moved it names the new owner in PT-AT's
    # row, and only its stored state names the owner it left.
    it 'reads the owner each child held until a first version that did not create it' do
      left = TrackedArticle.create!(title: 'Left')
      detached = TrackedArticle.create!(title: 'Detached')
      moved = unversioned { left.comments.create!(body: 'moved') }
      quiet = unversioned { detached.comments.create!(body: 'detached') }
      start = Time.now.utc
      moved.update!(article: TrackedArticle.create!(title: 'New'))
      quiet.update!(body: 'edited')
      edge = described_class::FirstVersion.new(reflection(TrackedArticle, :comments), window(start))

      expect(first_owners(edge, [moved.id, quiet.id])).to eq([left.id, detached.id].sort)
      expect(first_owners(edge, TrackedComment.select(:id))).to eq([left.id, detached.id].sort)
      expect(first_owners(edge, [moved.id])).to eq([left.id])
      expect(edge.filter_type).to eq(:integer)
    end

    it 'reads no create, and no version after the first of a child' do
      article = TrackedArticle.create!(title: 'Owner')
      created = article.comments.create!(body: 'created')
      quiet = unversioned { article.comments.create!(body: 'quiet') }
      quiet.update!(body: 'first')
      other = TrackedArticle.create!(title: 'Other')
      start = Time.now.utc
      created.update!(article: other)
      quiet.update!(article: other)
      edge = described_class::FirstVersion.new(reflection(TrackedArticle, :comments), window(start))
      everything = described_class::FirstVersion.new(reflection(TrackedArticle, :comments), nil)

      expect(first_owners(edge, [created.id, quiet.id])).to eq([])
      expect(first_owners(everything, [created.id, quiet.id])).to eq([article.id])
    end

    it 'reads a first version saved after the window, which held the owner through it' do
      article = TrackedArticle.create!(title: 'Owner')
      quiet = unversioned { article.comments.create!(body: 'quiet') }
      start = Time.now.utc
      range = PaperTrailDiff::TimeRange.new(start..Time.now.utc)
      quiet.update!(article: TrackedArticle.create!(title: 'Later'))
      edge = described_class::FirstVersion.new(reflection(TrackedArticle, :comments), range)

      expect(first_owners(edge, [quiet.id])).to eq([article.id])
    end

    it 'reads only children held under one of the owner types' do
      holder = EdgeHolder.create!(title: 'Holder')
      document = EdgeSpecialDocument.create!(name: 'Document')
      held = unversioned { EdgeSticker.create!(label: 'held', holder: holder) }
      other = unversioned { EdgeSticker.create!(label: 'other', holder: document) }
      EdgeSticker.where(id: other.id).update_all(holder_id: holder.id)
      start = Time.now.utc
      [held, other].each { |sticker| sticker.reload.update!(holder: nil) }
      edge = described_class::FirstVersion.new(reflection(EdgeHolder, :stickers), window(start))
      documents = described_class::FirstVersion.new(reflection(EdgeSpecialDocument, :stickers),
                                                    window(start))

      expect(first_owners(edge, [held.id, other.id])).to eq([holder.id])
      expect(first_owners(documents, [held.id, other.id])).to eq([holder.id])
      expect(first_owners(documents, [held.id])).to eq([])
    end

    it 'reads ids given as values in slices of one statement each' do
      article = TrackedArticle.create!(title: 'Owner')
      quiet = unversioned { article.comments.create!(body: 'quiet') }
      start = Time.now.utc
      quiet.update!(article: TrackedArticle.create!(title: 'New'))
      edge = described_class::FirstVersion.new(reflection(TrackedArticle, :comments), window(start))
      ids = Array.new(PaperTrailDiff::Support::IDS_PER_STATEMENT) do |index|
        -index - 1
      end + [quiet.id]

      sql = statements { expect(edge.owners_of(ids).map(&:to_i)).to eq([article.id]) }
      expect(sql.length).to eq(2)
      expect(edge.owners_of([])).to eq([])
    end

    it 'reads only the stored state, and nothing from a version with none, or none for the key' do
      article = TrackedArticle.create!(title: 'Owner')
      stateless, keyless, kept = Array.new(3) do |index|
        unversioned do
          article.comments.create!(body: index.to_s)
        end
      end
      start = Time.now.utc
      other = TrackedArticle.create!(title: 'Other')
      [stateless, keyless, kept].each { |comment| comment.update!(article: other) }
      stateless.versions.last.update_column(:object, nil)
      version = keyless.versions.last
      keyless_state = version.object_deserialized.except('article_id')
      version.update_column(:object, PaperTrail.serializer.dump(keyless_state))
      edge = described_class::FirstVersion.new(reflection(TrackedArticle, :comments), window(start))

      sql = statements do
        expect(edge.owners([stateless.id, keyless.id, kept.id])).to eq([article.id])
      end
      expect(sql.grep(/\ASELECT \S+object\S* FROM/).length).to eq(1)
    end

    it 'takes the item_id type of the version table of the child' do
      edge = described_class::FirstVersion.new(reflection(StringItemPost, :notes), nil)

      expect(edge.filter_type).to eq(:string)
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

    it 'reads the owners with a target of its type when the window opened or after' do
      author = SourceTypeAuthor.create!(name: 'Author')
      tag = SourceTypeTag.create!(name: 'Tag')
      kept = SourceTypeLink.create!(target: author)
      SourceTypeLink.create!(target: author).update!(target: tag)
      joined = SourceTypeLink.create!(target: tag)
      left = SourceTypeLink.create!(target: author)
      start = Time.now.utc
      joined.update!(target: author)
      left.update!(target: tag)
      SourceTypeLink.create!(target: tag, origin: author)
      edge = described_class::BelongsTo.new(reflection(SourceTypeLink, :target), window(start),
                                            foreign_type: 'SourceTypeAuthor')
      SourceTypeLink.create!(target: author)

      owners = PaperTrail::Version.where(item_id: edge.typed_owners).distinct.pluck(:item_id)
      expect(owners.sort).to eq([kept.id, joined.id, left.id])
    end
  end
end
