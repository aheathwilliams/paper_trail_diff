# frozen_string_literal: true

require_relative '../support/core_database'

RSpec.describe 'scoped root selection' do
  before do
    PaperTrail::Version.delete_all
    CoreComment.delete_all
    CoreArticle.delete_all
  end

  def analyze(scope, limit: 10)
    PaperTrailDiff.analyze_scope(
      scope, limit: limit,
             within: (Time.now.utc - 3600)..(Time.now.utc + 60), close_on: :current
    )
  end

  it 'counts distinct roots rather than joined rows against the safety limit' do
    article = CoreArticle.create!(title: 'Joined', internal_note: 'stable')
    2.times { article.comments.create!(body: 'Match') }

    result = analyze(CoreArticle.joins(:comments), limit: 1)

    expect(result.analyses.keys).to eq([PaperTrailDiff::Endpoint.identity(article)])
  end

  it 'preserves the relation limit, offset, and ordering' do
    articles = 3.times.map do |index|
      CoreArticle.create!(title: "Article #{index}", internal_note: 'stable')
    end
    [CoreArticle.order(id: :desc), CoreArticle.order('core_articles.id DESC')].each do |ordered|
      expect(analyze(ordered.offset(1).limit(1)).analyses.keys)
        .to eq([PaperTrailDiff::Endpoint.identity(articles[1])])
    end
    expect(analyze(CoreArticle.limit(0)).analyses).to be_empty
  end

  it 'still rejects more distinct roots than the safety limit permits' do
    2.times { CoreArticle.create!(title: 'Article', internal_note: 'stable') }

    expect { analyze(CoreArticle.limit(5), limit: 1) }
      .to raise_error(PaperTrailDiff::BatchLimitExceededError)
  end

  it 'orders by joined columns and keeps searching past duplicate query pages' do
    older = CoreArticle.create!(title: 'Older', internal_note: 'stable')
    recent = CoreArticle.create!(title: 'Recent', internal_note: 'stable')
    older.comments.create!(body: 'Earlier', created_at: Time.utc(2030, 1, 1))
    7.times { recent.comments.create!(body: 'Later', created_at: Time.utc(2031, 1, 1)) }
    scope = CoreArticle.joins(:comments).order('core_comments.created_at DESC')

    expect(analyze(scope, limit: 2).analyses.keys)
      .to eq([recent, older].map { |article| PaperTrailDiff::Endpoint.identity(article) })
    expect { analyze(scope, limit: 1) }.to raise_error(PaperTrailDiff::BatchLimitExceededError)
    expect(analyze(scope.limit(2), limit: 1).analyses.keys)
      .to eq([PaperTrailDiff::Endpoint.identity(recent)])
  end

  it 'preserves eager-loaded relation ordering and pagination' do
    articles = 3.times.map do |index|
      article = CoreArticle.create!(title: "Article #{index}", internal_note: 'stable')
      2.times { article.comments.create!(body: 'Comment', created_at: Time.utc(2030 + index)) }
      article
    end
    scope = CoreArticle.includes(:comments).references(:comments)
                       .order('core_comments.created_at DESC').offset(1).limit(1)

    expect(analyze(scope, limit: 1).analyses.keys)
      .to eq([PaperTrailDiff::Endpoint.identity(articles[1])])
  end

  it 'keeps unreachable roots separate from the requested live page' do
    3.times { CoreArticle.create!(title: 'Live', internal_note: 'stable') }
    deleted = CoreArticle.create!(title: 'Deleted', internal_note: 'stable')
    deleted.destroy!
    result = analyze(CoreArticle.limit(2))

    expect(result.analyses.length).to eq(2)
    expect(result.unreachable).to eq([PaperTrailDiff::Endpoint.identity(deleted)])
  end
end
