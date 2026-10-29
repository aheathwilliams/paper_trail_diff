# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::TimeVersionRange do
  let(:start_time) { Time.utc(2032, 1, 1, 12) }

  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  # A create and three updates, a minute apart, read back newest first.
  def history
    article = FilterArticle.create!(title: 'Draft')
    %w[Review Edited Published].each { |title| article.update!(title: title) }
    versions = article.versions.reorder(:id).to_a
    versions.each_with_index do |version, index|
      version.update_columns(created_at: start_time + (index * 60))
    end
    allow(article).to receive(:versions).and_return(article.versions.reorder(id: :desc))
    [article, *versions]
  end

  def plan(article, within, version_scope: nil, live_endpoint: nil, context_required: false)
    described_class.new(
      article, time_range: PaperTrailDiff::TimeRange.new(within),
               version_scope: version_scope, live_endpoint: live_endpoint
    ).select_plan(context_required: context_required)
  end

  it 'selects the versions in the window oldest first, then the next one to close on' do
    article, _created, reviewed, edited, published = history

    selected = plan(article, reviewed.created_at..edited.created_at)

    expect(selected.versions).to eq([reviewed, edited, published])
    expect(selected.mutations).to eq([reviewed, edited])
    expect(selected.context_version).to eq(published)
    expect(selected.reconstruction_versions).to eq([reviewed, edited, published])
  end

  it 'applies the version scope to the window alone' do
    article, _created, reviewed, edited, = history
    latest = ->(versions) { versions.reorder(created_at: :desc).limit(1) }

    selected = plan(article, reviewed.created_at..edited.created_at, version_scope: latest)

    expect(selected.mutations).to eq([edited])
  end

  it 'bounds each selected version by the one after it, not by the next selected' do
    article, created, reviewed, edited, published = history
    skip_review = ->(versions) { versions.where.not(id: reviewed.id) }

    selected = plan(article, created.created_at...published.created_at, version_scope: skip_review)

    expect(selected.mutations).to eq([created, edited])
    expect(selected.steps).to eq([[created, reviewed], [edited, published]])
  end

  it 'closes an empty window after the last version on the live record when context is required' do
    article, _created, _reviewed, _edited, published = history
    window = (published.created_at + 1)..(published.created_at + 60)

    selected = plan(article, window, live_endpoint: article, context_required: true)

    expect(selected.closing_record).to equal(article)
    expect(selected.versions).to eq([])
  end

  it 'reads the root from the next version when only context is required' do
    article, created, reviewed, = history
    window = (created.created_at + 1)...reviewed.created_at

    expect(plan(article, window)).to be_empty
    expect(plan(article, window, context_required: true).versions).to eq([reviewed])
  end

  it 'closes on the live record when no version follows the window' do
    article, _created, _reviewed, _edited, published = history

    window = published.created_at..(published.created_at + 60)
    selected = plan(article, window, live_endpoint: article)

    expect(selected.versions).to eq([published])
    expect(selected.closing_record).to equal(article)
  end
end
