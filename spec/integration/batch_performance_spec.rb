# frozen_string_literal: true

require_relative '../support/core_database'

RSpec.describe 'batch reconstruction cost' do
  before do
    PaperTrail::Version.delete_all
    CoreArticle.delete_all
  end

  it 'normalizes plain checkpoints without reifying and preserves every adjacent change' do
    articles = 3.times.map do |index|
      article = CoreArticle.create!(title: "Root #{index}", internal_note: 'stable')
      4.times { |step| article.update!(title: "Root #{index} v#{step}") }
      article
    end
    calls = Hash.new(0)
    allow_any_instance_of(PaperTrail::Version).to receive(:reify)
      .and_wrap_original do |method, *args, **kwargs|
        calls[method.receiver.id] += 1
        method.call(*args, **kwargs)
      end

    report = PaperTrailDiff.analyze_many(
      articles, within: (Time.now.utc - 3600)..(Time.now.utc + 60), close_on: :current
    )

    expect(calls).to be_empty
    articles.each_with_index do |article, index|
      analysis = report.fetch(PaperTrailDiff::Endpoint.identity(article))
      expect(analysis.timeline.length).to eq(5)
      expect(analysis.from_snapshot).to be_nil
      expect(analysis.to_snapshot.attributes.fetch('title')).to eq("Root #{index} v3")
      expect(analysis.timeline.drop(1).map { |step| step.diff.attributes.fetch('title').to })
        .to eq(4.times.map { |step| "Root #{index} v#{step}" })
    end
  end

  it 'reuses a filtered mutation successor without folding skipped edits into it' do
    article = CoreArticle.create!(title: 'initial', internal_note: 'stable')
    %w[first second third fourth].each { |title| article.update!(title: title) }
    chosen = article.versions.order(:id).to_a.values_at(1, 3)
    calls = Hash.new(0)
    allow_any_instance_of(PaperTrail::Version).to receive(:reify)
      .and_wrap_original do |method, *args, **kwargs|
        calls[method.receiver.id] += 1
        method.call(*args, **kwargs)
      end

    analysis = PaperTrailDiff.analyze(
      article, within: (Time.now.utc - 3600)..(Time.now.utc + 60), close_on: :current,
               version_scope: ->(versions) { versions.where(id: chosen.map(&:id)) }
    )

    expect(calls).to be_empty
    expect(analysis.timeline.map { |step| step.diff.attributes.fetch('title').to })
      .to eq(%w[first third])
  end
end
