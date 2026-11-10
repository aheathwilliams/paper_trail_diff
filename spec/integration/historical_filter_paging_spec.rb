# frozen_string_literal: true

require_relative '../support/core_database'

RSpec.describe 'paging a historical filter with the relation' do
  before do
    PaperTrail::Version.delete_all
    CoreArticle.delete_all
  end

  let(:window) { (Time.now.utc - 3600)..(Time.now.utc + 60) }

  # Was titled Match and no longer is, so only its history selects it.
  def matching
    article = CoreArticle.create!(title: 'Match', internal_note: 'stable')
    article.update!(title: 'Moved on')
    article
  end

  def other
    article = CoreArticle.create!(title: 'Other', internal_note: 'stable')
    article.update!(title: 'Still other')
    article
  end

  def page(relation, limit:, **options)
    PaperTrailDiff.analyze_scope(relation, within: window, limit: limit,
                                           historical_filter: { title: 'Match' }, **options)
                  .roots.map(&:id)
  end

  it 'returns each page of the matches, counting only the page toward limit:' do
    matches = Array.new(5) { matching }.map(&:id)

    expect(page(CoreArticle.order(:id).limit(2), limit: 2)).to eq(matches.first(2))
    expect(page(CoreArticle.order(:id).limit(2).offset(2), limit: 2)).to eq(matches[2, 2])
    expect(page(CoreArticle.order(:id).limit(2).offset(4), limit: 2)).to eq(matches.last(1))
    expect(page(CoreArticle.order(id: :desc).limit(1), limit: 1)).to eq(matches.last(1))
  end

  it 'fills a page past records that do not match' do
    first = matching
    other
    second = matching
    matching

    expect(page(CoreArticle.order(:id).limit(2), limit: 2)).to eq([first.id, second.id])
  end

  it 'reads no history past the page' do
    stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 2)
    matches = Array.new(6) { matching }.map(&:id)

    # Two records, each with two versions in the window and none after it.
    expect(page(CoreArticle.order(:id).limit(2), limit: 2, max_filter_versions: 4))
      .to eq(matches.first(2))
    expect { page(CoreArticle.order(:id), limit: 10, max_filter_versions: 4) }
      .to raise_error(PaperTrailDiff::FilterLimitExceededError)
  end

  it 'still refuses a page larger than limit:' do
    3.times { matching }

    expect { page(CoreArticle.order(:id).limit(3), limit: 2) }
      .to raise_error(PaperTrailDiff::BatchLimitExceededError, /matched more than 2 roots/)
  end

  it 'still refuses more matches than limit: when the relation has no limit' do
    3.times { matching }

    expect { page(CoreArticle.order(:id), limit: 2) }
      .to raise_error(PaperTrailDiff::BatchLimitExceededError, /matched more than 2 roots/)
    expect { page(CoreArticle.order(:id).offset(1), limit: 2) }
      .to raise_error(PaperTrailDiff::BatchLimitExceededError, /matched more than 2 roots/)
  end
end
