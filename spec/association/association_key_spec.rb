# frozen_string_literal: true

require_relative '../support/association_database'

# Only reflections are read, apart from one comparison that is refused before
# any history is, so these reuse the fixture tables.
class KeyedSpecComment < ActiveRecord::Base
  self.table_name = 'tracked_comments'
  belongs_to :keyed_reviewer, class_name: 'TrackedAuthor', foreign_key: :body,
                              primary_key: :name, optional: true
  has_paper_trail
end

# Associations keyed on a column other than a primary key, and two that name
# the primary key explicitly.
class KeyedSpecArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  has_many :author_comments, class_name: 'TrackedComment', foreign_key: :reviewer_id,
                             primary_key: :author_id
  has_one :author_profile, class_name: 'TrackedProfile', foreign_key: :article_id,
                           primary_key: :author_id
  belongs_to :titled_author, class_name: 'TrackedAuthor', foreign_key: :title,
                             primary_key: :name, optional: true
  belongs_to :keyed_owner, polymorphic: true, primary_key: :name, optional: true,
                           foreign_key: :author_id, foreign_type: :title
  has_many :identity_comments, class_name: 'KeyedSpecComment', foreign_key: :article_id,
                               primary_key: :id
  belongs_to :identity_author, class_name: 'TrackedAuthor', foreign_key: :author_id,
                               primary_key: :id, optional: true
  has_many :author_comment_replies, through: :author_comments, source: :replies
  has_many :identity_comment_authors, through: :identity_comments, source: :keyed_reviewer
  has_paper_trail
end

# Keyed on its name, so a key named `id` is not its primary key. Versioned, so
# the key rule alone decides whether discovery lists the paths that reach it.
class KeyedSpecNamedAuthor < ActiveRecord::Base
  self.table_name = 'tracked_authors'
  self.primary_key = 'name'
  has_paper_trail
end

class KeyedSpecArticle
  belongs_to :named_author, class_name: 'KeyedSpecNamedAuthor', foreign_key: :title,
                            primary_key: :name, optional: true
  belongs_to :id_named_author, class_name: 'KeyedSpecNamedAuthor', foreign_key: :title,
                               primary_key: :id, optional: true
  has_many :id_keyed_authors, class_name: 'KeyedSpecNamedAuthor', foreign_key: :name,
                              primary_key: :id
end

# Saved by the one example that reads history; PT-AT reads every belongs_to's
# columns on save, so it declares no other association.
class KeyedSpecPost < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  has_many :author_comments, class_name: 'TrackedComment', foreign_key: :reviewer_id,
                             primary_key: :author_id
  has_paper_trail
end

# A through whose through part is itself a through with a keyed part.
class KeyedSpecAuthor < ActiveRecord::Base
  self.table_name = 'tracked_authors'
  has_many :articles, class_name: 'KeyedSpecArticle', foreign_key: :author_id
  has_many :article_comment_replies, through: :articles, source: :author_comment_replies
  has_paper_trail
end

RSpec.describe PaperTrailDiff::AssociationKey do
  def reason(model, name)
    described_class.unsupported_reason(model.reflect_on_association(name))
  end

  def keyed(owner, key)
    "#{owner} matches records by #{key} rather than the primary key, and association " \
      'history is recorded by primary key'
  end

  # PT-AT records a child's parent by the parent's ID, so history read by ID
  # would match an association keyed on another column to other records.
  it 'names an association keyed on a column other than a primary key' do
    expect(reason(KeyedSpecArticle, :author_comments))
      .to eq(keyed('KeyedSpecArticle#author_comments', 'author_id'))
    expect(reason(KeyedSpecArticle, :author_profile))
      .to eq(keyed('KeyedSpecArticle#author_profile', 'author_id'))
    expect(reason(KeyedSpecArticle, :titled_author))
      .to eq(keyed('KeyedSpecArticle#titled_author', 'name'))
    expect(reason(KeyedSpecArticle, :keyed_owner))
      .to eq(keyed('KeyedSpecArticle#keyed_owner', 'name'))
  end

  # A belongs_to's key is its target's; any other macro's is its owner's.
  it 'accepts an association without a key, or keyed on the primary key itself' do
    expect(reason(KeyedSpecArticle, :identity_comments)).to be_nil
    expect(reason(KeyedSpecArticle, :identity_author)).to be_nil
    expect(reason(KeyedSpecArticle, :named_author)).to be_nil
    expect(reason(KeyedSpecArticle, :id_keyed_authors)).to be_nil
    expect(reason(KeyedSpecArticle, :id_named_author))
      .to eq(keyed('KeyedSpecArticle#id_named_author', 'id'))
    expect(reason(TrackedArticle, :comments)).to be_nil
    expect(reason(TrackedArticle, :contributors)).to be_nil
  end

  it 'names the part of a through keyed on a column other than a primary key' do
    expect(reason(KeyedSpecArticle, :author_comment_replies))
      .to eq(keyed('KeyedSpecArticle#author_comments', 'author_id'))
    expect(reason(KeyedSpecArticle, :identity_comment_authors))
      .to eq(keyed('KeyedSpecComment#keyed_reviewer', 'name'))
    expect(reason(KeyedSpecAuthor, :article_comment_replies))
      .to eq(keyed('KeyedSpecArticle#author_comments', 'author_id'))
  end

  it 'is refused in every method and left out of discovery' do
    post = KeyedSpecPost.create!(title: 'Keyed')
    message = /unsupported association author_comments: KeyedSpecPost#author_comments/

    expect do
      PaperTrailDiff.compare(post.versions.first, post, associations: [:author_comments])
    end.to raise_error(PaperTrailDiff::UnsupportedAssociationError, message)
    expect(PaperTrailDiff.association_paths(KeyedSpecArticle).map(&:path))
      .to eq(%w[id_keyed_authors identity_author identity_comments named_author])
  ensure
    PaperTrail::Version.delete_all
    KeyedSpecPost.delete_all
  end
end
