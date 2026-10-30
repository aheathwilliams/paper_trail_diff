# frozen_string_literal: true

require_relative '../support/association_database'

# Only reflections are read, so these reuse the fixture tables. Scopes written
# as SQL strings cannot be read from stored attributes; hash conditions on
# integer columns can, on every adapter.
class BatchSafetyComment < ActiveRecord::Base
  self.table_name = 'tracked_comments'
  default_scope { where("body <> ''") }
end

class BatchSafetyReviewedComment < ActiveRecord::Base
  self.table_name = 'tracked_comments'
  default_scope { where.not(reviewer_id: nil) }
end

class BatchSafetyAuthorship < ActiveRecord::Base
  self.table_name = 'tracked_authorships'
  belongs_to :author, class_name: 'TrackedAuthor'
  belongs_to :scoped_author, -> { where("name <> ''") }, class_name: 'TrackedAuthor',
                                                         foreign_key: :author_id
  belongs_to :plain_author, -> { where(id: [1, 2]) }, class_name: 'TrackedAuthor',
                                                      foreign_key: :author_id
  has_many :comments, through: :author, source: :reviewed_comments
end

class BatchSafetyArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  belongs_to :owner, polymorphic: true, optional: true
  belongs_to :scoped_owner, -> { where(id: 1) }, polymorphic: true, optional: true,
                                                 foreign_key: :owner_id, foreign_type: :owner_type
  has_many :default_scoped_comments, class_name: 'BatchSafetyComment', foreign_key: :article_id
  has_many :reviewed_comments, class_name: 'BatchSafetyReviewedComment', foreign_key: :article_id
  has_many :unreviewed_comments, -> { where(reviewer_id: nil) }, class_name: 'TrackedComment',
                                                                 foreign_key: :article_id
  has_many :authorships, class_name: 'BatchSafetyAuthorship', foreign_key: :article_id
  has_many :editorships, -> { where('role = ?', 'editor') }, class_name: 'BatchSafetyAuthorship',
                                                             foreign_key: :article_id
  has_many :first_authorships, -> { where(author_id: 1) }, class_name: 'BatchSafetyAuthorship',
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

RSpec.describe PaperTrailDiff::BatchSafety do
  def safety(paths, **options)
    traversal = PaperTrailDiff::AssociationTraversal.new(PaperTrailDiff::AssociationTree.build(paths))
    described_class.new(traversal, allow_expensive: false, **options)
  end

  it 'accepts direct paths and throughs of any source, nested throughs included' do
    expect { safety(%i[comments contributors]).call(TrackedArticle) }.not_to raise_error
    expect { safety([:comments]).call(TrackedAuthor) }.not_to raise_error
    expect { safety(%i[authorship_comments comment_articles]).call(BatchSafetyArticle) }
      .not_to raise_error
  end

  it 'accepts scopes and default scopes it can read as conditions on stored attributes' do
    expect do
      safety(%i[unreviewed_comments reviewed_comments first_authors first_comments])
        .call(BatchSafetyArticle)
    end.not_to raise_error
    expect { safety(%i[limited_comments offset_comments]).call(TrackedArticle) }.not_to raise_error
    expect { safety(['authorships.plain_author']).call(BatchSafetyArticle) }.not_to raise_error
  end

  it 'rejects a scope on a polymorphic belongs_to, whose target class is not known' do
    expect { safety([:scoped_owner]).call(BatchSafetyArticle) }
      .to raise_error(PaperTrailDiff::UnsupportedBatchPathError,
                      /\Aassociation scoped_owner .*\(association scope\)/)
  end

  it 'rejects scopes with an actionable opt-in' do
    [[TrackedArticle, :owner_comments], [BatchSafetyArticle, :body_ranked_comments]]
      .each do |model, path|
        expect { safety([path]).call(model) }
          .to raise_error(PaperTrailDiff::UnsupportedBatchPathError,
                          /#{path}.*allow_expensive: true/)
        expect { safety([path], allow_expensive: true).call(model) }.not_to raise_error
      end
  end

  # A has_many through keeps only its parts' conditions; a has_one through
  # orders by its parts too and takes the first row.
  it 'accepts a has_many through a ranked part, and rejects a has_one through one' do
    expect do
      safety(%i[first_comment_replies lead_comment_replies body_ranked_comment_replies
                lead_reviewer_authorships]).call(BatchSafetyArticle)
    end.not_to raise_error
    expect { safety([:lead_comment_reviewer]).call(BatchSafetyArticle) }
      .to raise_error(PaperTrailDiff::UnsupportedBatchPathError,
                      /\Aassociation lead_comment_reviewer .*\(limit, offset or has_one order/)
  end

  it 'requires an explicit boolean opt-in' do
    ['yes', nil].each do |value|
      expect { safety([], allow_expensive: value) }
        .to raise_error(PaperTrailDiff::ConfigurationError,
                        'allow_expensive: must be true or false')
    end
  end

  it 'names the path, the reason and the opt-in in its message' do
    expect { safety([:default_scoped_comments]).call(BatchSafetyArticle) }
      .to raise_error(
        PaperTrailDiff::UnsupportedBatchPathError,
        'association default_scoped_comments requires per-record reconstruction ' \
        '(default-scoped target); remove this path or explicitly pass allow_expensive: true'
      )
  end

  it 'accepts a polymorphic belongs_to, whose target class is not known' do
    expect { safety([:owner]).call(BatchSafetyArticle) }.not_to raise_error
  end

  it 'checks both halves of a through path under the outer path name' do
    expect { safety([:editors]).call(BatchSafetyArticle) }
      .to raise_error(PaperTrailDiff::UnsupportedBatchPathError,
                      /\Aassociation editors .*\(association scope\)/)
    expect { safety([:scoped_contributors]).call(BatchSafetyArticle) }
      .to raise_error(PaperTrailDiff::UnsupportedBatchPathError,
                      /\Aassociation scoped_contributors .*\(association scope\)/)
  end

  it 'checks the parts of a through that is itself the through half' do
    expect { safety([:editorship_comment_articles]).call(BatchSafetyArticle) }
      .to raise_error(PaperTrailDiff::UnsupportedBatchPathError,
                      /\Aassociation editorship_comment_articles .*\(association scope\)/)
  end

  it 'checks nested paths below the root' do
    expect { safety(['authorships.scoped_author']).call(BatchSafetyArticle) }
      .to raise_error(PaperTrailDiff::UnsupportedBatchPathError,
                      /\Aassociation authorships\.scoped_author /)
  end

  it 'enforces the policy on public reports before selecting roots' do
    allow(TrackedArticle).to receive(:pluck).and_call_original
    expect do
      PaperTrailDiff.report(TrackedArticle, since: Time.now.utc - 60,
                                            limit: 5, associations: [:owner_comments])
    end.to raise_error(PaperTrailDiff::UnsupportedBatchPathError, /owner_comments/)
    expect(TrackedArticle).not_to have_received(:pluck)
  end

  it 'permits live-only through comparisons without an expensive-history opt-in' do
    author = TrackedAuthor.create!(name: 'Live through')
    expect do
      PaperTrailDiff.compare_many([{ from: author, to: author }], associations: [:comments])
    end.not_to raise_error
  end
end
