# frozen_string_literal: true

require_relative '../support/association_database'

# Only reflections are read, so these reuse the fixture tables. Scopes written
# as SQL strings cannot be read from stored attributes; hash conditions on
# integer columns can, on every adapter.
class ApproximatePathsComment < ActiveRecord::Base
  self.table_name = 'tracked_comments'
  default_scope { where("body <> ''") }
end

class ApproximatePathsReviewedComment < ActiveRecord::Base
  self.table_name = 'tracked_comments'
  default_scope { where.not(reviewer_id: nil) }
end

class ApproximatePathsAuthorship < ActiveRecord::Base
  self.table_name = 'tracked_authorships'
  belongs_to :author, class_name: 'TrackedAuthor'
  belongs_to :scoped_author, -> { where("name <> ''") }, class_name: 'TrackedAuthor',
                                                         foreign_key: :author_id
  belongs_to :plain_author, -> { where(id: [1, 2]) }, class_name: 'TrackedAuthor',
                                                      foreign_key: :author_id
  has_many :comments, through: :author, source: :reviewed_comments
end

class ApproximatePathsArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  belongs_to :owner, polymorphic: true, optional: true
  belongs_to :scoped_owner, -> { where(id: 1) }, polymorphic: true, optional: true,
                                                 foreign_key: :owner_id, foreign_type: :owner_type
  has_many :default_scoped_comments, class_name: 'ApproximatePathsComment', foreign_key: :article_id
  has_many :reviewed_comments, class_name: 'ApproximatePathsReviewedComment',
                               foreign_key: :article_id
  has_many :unreviewed_comments, -> { where(reviewer_id: nil) }, class_name: 'TrackedComment',
                                                                 foreign_key: :article_id
  has_many :authorships, class_name: 'ApproximatePathsAuthorship', foreign_key: :article_id
  has_many :editorships, -> { where('role = ?', 'editor') },
           class_name: 'ApproximatePathsAuthorship', foreign_key: :article_id
  has_many :first_authorships, -> { where(author_id: 1) }, class_name: 'ApproximatePathsAuthorship',
                                                           foreign_key: :article_id
  has_many :first_authors, -> { where.not(id: nil) }, through: :first_authorships,
                                                      source: :plain_author
  has_many :editors, through: :editorships, source: :author
  has_many :scoped_contributors, through: :authorships, source: :scoped_author
  has_many :authorship_comments, through: :authorships, source: :comments
  has_many :comment_articles, through: :authorship_comments, source: :article
  has_many :editorship_comments, through: :editorships, source: :comments
  has_many :editorship_comment_articles, through: :editorship_comments, source: :article
  # A string order follows a collation, so its ranking is not read.
  has_many :body_ranked_comments, -> { order(:body, :id).limit(1) },
           class_name: 'TrackedComment', foreign_key: :article_id
  has_many :first_comments, -> { order(:id).limit(1) }, class_name: 'TrackedComment',
                                                        foreign_key: :article_id
  has_many :first_comment_replies, through: :first_comments, source: :replies
  has_one :lead_comment, -> { order(:id) }, class_name: 'TrackedComment', foreign_key: :article_id
  has_one :lead_comment_reviewer, through: :lead_comment, source: :reviewer
  has_many :lead_comment_replies, through: :lead_comment, source: :replies
  has_many :body_ranked_comment_replies, through: :body_ranked_comments, source: :replies
  has_many :lead_reviewer_authorships, through: :lead_comment_reviewer, source: :authorships
end

RSpec.describe PaperTrailDiff::ApproximatePaths do
  def paths(model, requested)
    tree = PaperTrailDiff::AssociationTree.build(requested)
    described_class.call(PaperTrailDiff::AssociationTraversal.new(tree), model)
  end

  it 'accepts direct paths and throughs of any source, nested throughs included' do
    expect(paths(TrackedArticle, %i[comments contributors])).to eq([])
    expect(paths(TrackedAuthor, [:comments])).to eq([])
    expect(paths(ApproximatePathsArticle, %i[authorship_comments comment_articles])).to eq([])
  end

  it 'accepts scopes and default scopes it can read as conditions on stored attributes' do
    expect(paths(ApproximatePathsArticle,
                 %i[unreviewed_comments reviewed_comments first_authors first_comments]))
      .to eq([])
    expect(paths(TrackedArticle, %i[limited_comments offset_comments])).to eq([])
    expect(paths(ApproximatePathsArticle, ['authorships.plain_author'])).to eq([])
  end

  it 'names a scope on a polymorphic belongs_to, whose target class is not known' do
    expect(paths(ApproximatePathsArticle, [:scoped_owner]))
      .to eq([['scoped_owner', 'association scope']])
  end

  it 'names a scope it cannot read, and a default-scoped target' do
    expect(paths(TrackedArticle, [:owner_comments]))
      .to eq([['owner_comments', 'association scope']])
    expect(paths(ApproximatePathsArticle, %i[body_ranked_comments default_scoped_comments]))
      .to eq([['body_ranked_comments', 'association scope'],
              ['default_scoped_comments', 'default-scoped target']])
  end

  # A has_many through keeps only its parts' conditions; a has_one through
  # orders by its parts too and takes the first row.
  it 'accepts a has_many through a ranked part, and names a has_one through one' do
    expect(paths(ApproximatePathsArticle,
                 %i[first_comment_replies lead_comment_replies body_ranked_comment_replies
                    lead_reviewer_authorships]))
      .to eq([])
    expect(paths(ApproximatePathsArticle, [:lead_comment_reviewer]))
      .to eq([['lead_comment_reviewer', 'limit, offset or has_one order inside a has_one through']])
  end

  it 'accepts a polymorphic belongs_to, whose target class is not known' do
    expect(paths(ApproximatePathsArticle, [:owner])).to eq([])
  end

  it 'checks both halves of a through path under the outer path name' do
    expect(paths(ApproximatePathsArticle, %i[editors scoped_contributors]))
      .to eq([['editors', 'association scope'], ['scoped_contributors', 'association scope']])
  end

  it 'checks the parts of a through that is itself the through half' do
    expect(paths(ApproximatePathsArticle, [:editorship_comment_articles]))
      .to eq([['editorship_comment_articles', 'association scope']])
  end

  it 'checks nested paths below the root' do
    expect(paths(ApproximatePathsArticle, ['authorships.scoped_author']))
      .to eq([['authorships.scoped_author', 'association scope']])
  end

  it 'is refused on public reports before selecting roots' do
    allow(TrackedArticle).to receive(:pluck).and_call_original
    expect do
      PaperTrailDiff.report(TrackedArticle, since: Time.now.utc - 60,
                                            limit: 5, associations: [:owner_comments])
    end.to raise_error(PaperTrailDiff::UnsupportedAssociationError, /owner_comments/)
    expect(TrackedArticle).not_to have_received(:pluck)
  end

  it 'permits live-only through comparisons without an opt-in' do
    author = TrackedAuthor.create!(name: 'Live through')
    expect do
      PaperTrailDiff.compare_many([{ from: author, to: author }], associations: [:comments])
    end.not_to raise_error
  end
end
