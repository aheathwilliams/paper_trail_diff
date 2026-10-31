# frozen_string_literal: true

require_relative '../support/core_database'

# A scope on the versions association hides versions from the app, but a
# history replayed without them credits their changes to the next version
# kept. Every method reads every version, as batch methods always did.
RSpec.describe 'has_paper_trail versions: { scope: }' do
  before do
    PaperTrail::Version.delete_all
    ScopedHistoryArticle.delete_all
  end

  # The editor's change sits between two the scope leaves out.
  def history
    article = ScopedHistoryArticle.create!(title: 'a')
    PaperTrail.request(whodunnit: 'bot') { article.update!(title: 'b') }
    PaperTrail.request(whodunnit: 'editor') { article.update!(title: 'c') }
    PaperTrail.request(whodunnit: 'bot') { article.update!(title: 'd') }
    article
  end

  def changes(steps)
    steps.drop(1).map do |step|
      change = step.diff.attributes.fetch('title')
      [step.source_boundary.whodunnit, change.from, change.to]
    end
  end

  let(:expected) { [%w[bot a b], %w[editor b c], %w[bot c d]] }
  let(:window) { (Time.now.utc - 3600)..(Time.now.utc + 60) }

  it 'credits each change to its own version in single-record methods' do
    article = history

    expect(changes(PaperTrailDiff.timeline(article))).to eq(expected)
    expect(changes(PaperTrailDiff.timeline(article, within: window))).to eq(expected)
    expect(changes(PaperTrailDiff.analyze(article).timeline)).to eq(expected)
    expect(changes(PaperTrailDiff.activity_timeline(article))).to eq(expected)
  end

  it 'agrees with the batch methods' do
    article = history
    key = ['ScopedHistoryArticle', article.id.to_s]

    many = PaperTrailDiff.analyze_many([article], within: window).fetch(key)
    scoped = PaperTrailDiff.analyze_scope(ScopedHistoryArticle.all, within: window, limit: 10)

    expect(changes(many.timeline)).to eq(expected)
    expect(changes(scoped.analyses.fetch(key).timeline)).to eq(expected)
  end

  it 'accepts a version the scope leaves out as an endpoint' do
    article = history
    hidden = PaperTrail::Version.where(item_type: 'ScopedHistoryArticle', whodunnit: 'bot')
                                .order(:id).first

    steps = PaperTrailDiff.timeline(article, from: hidden)
    diff = PaperTrailDiff.compare(hidden, article)

    expect(changes([nil, *steps])).to eq(expected)
    expect([diff.attributes.fetch('title').from, diff.attributes.fetch('title').to]).to eq(%w[a d])
  end
end
