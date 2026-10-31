# frozen_string_literal: true

require_relative '../support/association_database'

# Active Record's preloader applies a limit or offset to all the records it
# loads at once, so a preloaded limited association holds another record's
# share, or none.
RSpec.describe PaperTrailDiff::PreloadedEndpointBatchLoader do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
  end

  def articles
    Array.new(3) do |index|
      article = TrackedArticle.create!(title: "Article #{index}")
      2.times { |position| article.comments.create!(body: "Comment #{index}.#{position}") }
      article.update!(title: "Article #{index}, edited")
      article
    end
  end

  def comparisons(records)
    records.map { |record| { from: record.versions.reorder(:created_at, :id).first, to: record } }
  end

  %i[limited_comments offset_comments].each do |name|
    it "reads a preloaded #{name} again for each record" do
      ids = articles.map(&:id)
      preloaded = TrackedArticle.where(id: ids).order(:id).preload(name).to_a

      reused = PaperTrailDiff.compare_many(comparisons(preloaded), associations: [name],
                                                                   reload_live_endpoints: false)
      fresh = TrackedArticle.where(id: ids).order(:id).to_a
      reloaded = PaperTrailDiff.compare_many(comparisons(fresh), associations: [name])

      expect(reused.transform_values(&:to_h)).to eq(reloaded.transform_values(&:to_h))
      expect(preloaded.map { |article| article.public_send(name).size }).to eq([1, 1, 1])
    end
  end

  it 'still refuses a limited association the caller did not load' do
    article, = articles

    expect do
      PaperTrailDiff.compare(article.versions.first, TrackedArticle.find(article.id),
                             associations: [:limited_comments], reload_live_endpoints: false)
    end.to raise_error(PaperTrailDiff::UnloadedAssociationError, /limited_comments/)
  end

  it 'leaves an association a batch preload loads correctly as the caller loaded it' do
    article, = articles
    preloaded = TrackedArticle.preload(:comments).find(article.id)
    loaded = preloaded.comments.target

    PaperTrailDiff.compare(article.versions.first, preloaded, associations: [:comments],
                                                              reload_live_endpoints: false)

    expect(preloaded.comments.target).to equal(loaded)
  end
end
