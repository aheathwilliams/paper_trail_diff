# frozen_string_literal: true

require_relative '../support/core_database'

# PaperTrail never writes a `skip:` column to a version, so history holds only
# its default. Comparing that default with the live row would invent a change.
RSpec.describe 'has_paper_trail skip: columns' do
  before do
    PaperTrail::Version.delete_all
    SkippingArticle.delete_all
  end

  def history
    article = SkippingArticle.create!(title: 'Draft')
    article.update!(view_count: 500)
    article.update!(title: 'Published')
    article
  end

  it 'is left out when a version is compared with the live record' do
    article = history

    diff = PaperTrailDiff.compare(article.versions.last, article)

    expect(diff.attributes.keys).to eq(['title'])
  end

  it 'is left out of snapshots and of timelines ending at current state' do
    article = history

    analysis = PaperTrailDiff.analyze(article, from: :first, to: article)

    expect(analysis.to_snapshot.attributes).not_to have_key('view_count')
    expect(analysis.timeline.flat_map { |step| step.diff.attributes.keys }).to eq(['title'])
  end
end
