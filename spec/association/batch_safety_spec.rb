# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe PaperTrailDiff::BatchSafety do
  def safety(paths, **options)
    traversal = PaperTrailDiff::AssociationTraversal.new(PaperTrailDiff::AssociationTree.build(paths))
    described_class.new(traversal, allow_expensive: false, **options)
  end

  it 'accepts ordinary direct and belongs-to through paths' do
    expect { safety(%i[comments contributors]).call(TrackedArticle) }.not_to raise_error
  end

  it 'rejects scopes with an actionable opt-in' do
    %i[limited_comments owner_comments].each do |path|
      expect { safety([path]).call(TrackedArticle) }
        .to raise_error(PaperTrailDiff::UnsupportedBatchPathError, /#{path}.*allow_expensive: true/)
      expect { safety([path], allow_expensive: true).call(TrackedArticle) }.not_to raise_error
    end
  end

  it 'rejects historical collection through sources but allows live loading' do
    expect { safety([:comments]).call(TrackedAuthor) }
      .to raise_error(PaperTrailDiff::UnsupportedBatchPathError, /through source/)
    expect { safety([:comments]).call(TrackedAuthor, historical: false) }.not_to raise_error
  end

  it 'requires an explicit boolean opt-in' do
    expect { safety([], allow_expensive: 'yes') }
      .to raise_error(PaperTrailDiff::ConfigurationError, /true or false/)
  end

  it 'enforces the policy on public reports before selecting roots' do
    expect(TrackedArticle).not_to receive(:pluck)
    expect do
      PaperTrailDiff.report(TrackedArticle, since: Time.now.utc - 60,
                                            limit: 5, associations: [:limited_comments])
    end.to raise_error(PaperTrailDiff::UnsupportedBatchPathError, /limited_comments/)
  end

  it 'permits live-only through comparisons without an expensive-history opt-in' do
    author = TrackedAuthor.create!(name: 'Live through')
    expect do
      PaperTrailDiff.compare_many([{ from: author, to: author }], associations: [:comments])
    end.not_to raise_error
  end
end
