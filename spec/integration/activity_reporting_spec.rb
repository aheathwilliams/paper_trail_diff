# frozen_string_literal: true

require_relative '../support/core_database'

RSpec.describe 'activity reporting at current state' do
  before do
    PaperTrail::Version.delete_all
    CoreArticle.delete_all
  end

  def options
    { within: (Time.now.utc - 3600)..(Time.now.utc + 60), close_on: :current }
  end

  it 'reports a lone creation without requiring a preceding step' do
    article = CoreArticle.create!(title: 'Created', internal_note: 'stable')
    steps = PaperTrailDiff.activity_timeline(article, **options, snapshots: true)

    expect(steps.length).to eq(1)
    expect(steps.first.from_boundary.event).to eq('create')
    expect(steps.first.to_boundary).to be_current
    expect(steps.first.diff.record_presence_change.to.id).to eq(article.id)
    expect(steps.first.to_snapshot.attributes.fetch('title')).to eq('Created')
  end

  it 'reports a lone in-window update as an update, not a creation' do
    article = CoreArticle.create!(title: 'Before', internal_note: 'stable')
    article.versions.last.update_columns(created_at: Time.now.utc - 7200)
    article.update!(title: 'After')
    step = PaperTrailDiff.activity_timeline(article, **options).fetch(0)

    expect(step.diff.record_presence_change).to be_nil
    expect(step.diff.attributes.fetch('title').to_h).to eq(from: 'Before', to: 'After')
  end

  it 'returns the same current state and changes in single, batch, and scope analysis' do
    article = CoreArticle.create!(title: 'Before', internal_note: 'stable')
    article.update!(title: 'After')
    single = PaperTrailDiff.analyze(article, **options, activity: true)
    batch = PaperTrailDiff.analyze_many([article], **options, activity: true).values.fetch(0)
    scoped = PaperTrailDiff.analyze_scope(CoreArticle, limit: 1, **options,
                                                       activity: true).analyses.values.fetch(0)

    [batch, scoped].each do |result|
      expect(result.to_snapshot.to_h).to eq(single.to_snapshot.to_h)
      expect(result.diff.to_h).to eq(single.diff.to_h)
      expect(result.timeline.map { |step| step.diff.to_h })
        .to eq(single.timeline.map { |step| step.diff.to_h })
      expect(result.activity_timeline.map { |step| step.diff.to_h })
        .to eq(single.activity_timeline.map { |step| step.diff.to_h })
      expect(result.activity_timeline.last.to_boundary).to be_current
    end
  end

  it 'accepts the same explicit current endpoint in all single-record timeline views' do
    article = CoreArticle.create!(title: 'Before', internal_note: 'stable')
    article.update!(title: 'After')
    range = { from: :first, to: article }
    timeline = PaperTrailDiff.timeline(article, **range)
    analysis = PaperTrailDiff.analyze(article, **range)
    activity = PaperTrailDiff.analyze(article, **range, activity: true)

    expect(timeline.last.diff.attributes.fetch('title').to_h).to eq(from: 'Before', to: 'After')
    expect(analysis.to_snapshot.attributes.fetch('title')).to eq('After')
    expect(activity.to_snapshot.to_h).to eq(analysis.to_snapshot.to_h)
    expect(activity.timeline.map { |step| step.diff.to_h }).to eq(timeline.map { |step|
      step.diff.to_h
    })
    expect(activity.activity_timeline.last.to_boundary).to be_current
    step = timeline.last
    expect(step.source_boundary).to equal(step.from_boundary)
    expect(step.to_h).not_to have_key(:from_boundary)
    expect(step.to_h(metadata: true).fetch(:from_boundary)).to include(event: 'update')
    expect(step.to_h(metadata: true).fetch(:to_boundary)).to include(event: nil)
  end

  it 'returns empty results for explicit current endpoints when no versions exist' do
    article = PaperTrail.request(enabled: false) do
      CoreArticle.create!(title: 'No history', internal_note: 'stable')
    end

    expect(PaperTrailDiff.timeline(article, from: :first, to: article)).to be_empty
    expect(PaperTrailDiff.analyze(article, from: :first, to: article,
                                           activity: true).diff).to be_empty
  end

  it 'preserves the filtered closing boundary when a later event is excluded' do
    article = CoreArticle.create!(title: 'Before', internal_note: 'stable')
    PaperTrail.request(whodunnit: 'alice') { article.update!(title: 'Selected') }
    PaperTrail.request(whodunnit: 'bob') { article.update!(title: 'Excluded') }
    analysis = PaperTrailDiff.analyze(
      article, from: :first, to: article, activity: true,
               version_scope: ->(versions) { versions.where(whodunnit: 'alice') }
    )

    expect(analysis.diff.attributes.fetch('title').to_h).to eq(from: 'Before', to: 'Selected')
    expect(analysis.activity_timeline.last.to_boundary).to be_version
  end

  it 'rejects unsupported grouping and grouping without activity even for empty batches' do
    expect { PaperTrailDiff.analyze_many([], activity: true, group: :typo) }
      .to raise_error(PaperTrailDiff::ConfigurationError, /group:/)
    expect { PaperTrailDiff.analyze_many([], group: :transaction) }
      .to raise_error(PaperTrailDiff::ConfigurationError, /requires activity/)
  end

  it 'rejects retaining activity snapshots without requesting activity' do
    article = CoreArticle.create!(title: 'Article', internal_note: 'stable')
    calls = [
      -> { PaperTrailDiff.analyze(article, **options, snapshots: true) },
      -> { PaperTrailDiff.analyze_many([], snapshots: true) },
      -> { PaperTrailDiff.analyze_scope(CoreArticle.none, limit: 1, snapshots: true) },
      -> { PaperTrailDiff.analyze_many(scope: CoreArticle.none, limit: 1, snapshots: true) }
    ]

    calls.each do |call|
      expect(&call).to raise_error(PaperTrailDiff::ConfigurationError,
                                   /snapshots: requires activity/)
    end
  end
end
