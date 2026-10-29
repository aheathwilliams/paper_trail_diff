# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe PaperTrailDiff::ComparisonBatch do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedComment, TrackedArticle].each(&:delete_all)
  end

  let(:prepared) { [] }
  let(:version_prepared) { [] }

  def batch(comparisons)
    described_class.new(
      comparisons,
      live_loader: ->(records) { records.to_h { |record| [identity(record), record] } },
      preparer: ->(_model, historical:) {},
      history_preparer: ->(records, versions) { prepared << [records, versions] },
      version_history_preparer: ->(records, versions) { version_prepared << [records, versions] },
      historical_snapshotter: ->(_version) {},
      live_normalizer: ->(_record) {}
    )
  end

  def identity(endpoint)
    PaperTrailDiff::Endpoint.identity(endpoint)
  end

  def versions_of(article)
    2.times { |index| article.update!(title: "Title #{index}") }
    article.versions.reorder(:created_at, :id).to_a
  end

  it 'prepares a root compared between versions from its identity alone' do
    article = TrackedArticle.create!(title: 'Article')
    first, *, last = versions_of(article)

    batch([{ from: first, to: last }]).call

    expect(prepared).to eq([])
    records, versions = version_prepared.fetch(0)
    expect(version_prepared.length).to eq(1)
    expect(records.map { |record| [record.class, record.id, record.persisted?] })
      .to eq([[TrackedArticle, article.id, false]])
    expect(versions).to eq([first, last])
  end

  it 'prepares each version-only root once, with all of its versions' do
    article = TrackedArticle.create!(title: 'Article')
    other = TrackedArticle.create!(title: 'Other')
    article_versions = versions_of(article)
    other_versions = versions_of(other)

    batch([{ from: article_versions[0], to: article_versions[1] },
           { from: other_versions[1], to: other_versions[1] }]).call

    records, versions = version_prepared.fetch(0)
    expect(version_prepared.length).to eq(1)
    expect(records.map(&:id)).to eq([article.id, other.id])
    expect(versions).to eq([article_versions[0], article_versions[1], other_versions[1]])
  end

  it 'prepares a root with a live endpoint from that record' do
    article = TrackedArticle.create!(title: 'Article')
    first, = versions_of(article)
    other = TrackedArticle.create!(title: 'Other')
    other_first, other_last = versions_of(other)

    batch([{ from: first, to: article }, { from: other_first, to: other_last }]).call

    expect(prepared).to eq([[[article], [first]]])
    records, versions = version_prepared.fetch(0)
    expect(records.map(&:id)).to eq([other.id])
    expect(versions).to eq([other_first, other_last])
  end

  it 'prepares no history for a pair of live records' do
    article = TrackedArticle.create!(title: 'Article')

    batch([{ from: article, to: article }]).call

    expect(prepared).to eq([])
    expect(version_prepared).to eq([])
  end
end
