# frozen_string_literal: true

require_relative '../support/association_database'

# Only reflections are read, so these reuse the fixture tables.
class BatchSafetyComment < ActiveRecord::Base
  self.table_name = 'tracked_comments'
  default_scope { where.not(body: '') }
end

class BatchSafetyAuthorship < ActiveRecord::Base
  self.table_name = 'tracked_authorships'
  belongs_to :author, class_name: 'TrackedAuthor'
  belongs_to :scoped_author, -> { where.not(name: '') }, class_name: 'TrackedAuthor',
                                                         foreign_key: :author_id
  has_many :comments, class_name: 'TrackedComment', foreign_key: :article_id,
                      primary_key: :article_id
end

class BatchSafetyArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  belongs_to :owner, polymorphic: true, optional: true
  has_many :default_scoped_comments, class_name: 'BatchSafetyComment', foreign_key: :article_id
  has_many :authorships, class_name: 'BatchSafetyAuthorship', foreign_key: :article_id
  has_many :editorships, -> { where(role: 'editor') }, class_name: 'BatchSafetyAuthorship',
                                                       foreign_key: :article_id
  has_many :editors, through: :editorships, source: :author
  has_many :scoped_contributors, through: :authorships, source: :scoped_author
  has_many :authorship_comments, through: :authorships, source: :comments
  has_many :comment_articles, through: :authorship_comments, source: :article
  has_many :editorship_comments, through: :editorships, source: :comments
  has_many :editorship_comment_articles, through: :editorship_comments, source: :article
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

  it 'rejects scopes with an actionable opt-in' do
    %i[limited_comments owner_comments].each do |path|
      expect { safety([path]).call(TrackedArticle) }
        .to raise_error(PaperTrailDiff::UnsupportedBatchPathError, /#{path}.*allow_expensive: true/)
      expect { safety([path], allow_expensive: true).call(TrackedArticle) }.not_to raise_error
    end
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
                                            limit: 5, associations: [:limited_comments])
    end.to raise_error(PaperTrailDiff::UnsupportedBatchPathError, /limited_comments/)
    expect(TrackedArticle).not_to have_received(:pluck)
  end

  it 'permits live-only through comparisons without an expensive-history opt-in' do
    author = TrackedAuthor.create!(name: 'Live through')
    expect do
      PaperTrailDiff.compare_many([{ from: author, to: author }], associations: [:comments])
    end.not_to raise_error
  end
end
