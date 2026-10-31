# frozen_string_literal: true

require_relative '../support/association_database'

# What a window adds to an activity replay: it reports only the events inside
# it, it closes on a final destroy or on the live row, and its analysis ends
# where it closes.
RSpec.describe 'Activity over a window',
               mutant_expression: 'PaperTrailDiff::ActivityTimelineBuilder' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    ActiveRecord::Base.connection.execute('DELETE FROM tracked_articles_tags')
    [TrackedComment, TrackedArticle, TrackedTag].each(&:delete_all)
  end

  def timeline(article, **options)
    PaperTrailDiff.activity_timeline(article, associations: [:comments], **options)
  end

  def analysis(article, **options)
    PaperTrailDiff.analyze(article, associations: [:comments], activity: true, **options)
  end

  def checkpoint(article)
    TrackedArticle.transaction { TrackedArticle.find(article.id).paper_trail.save_with_version }
  end

  def now
    Time.now.utc
  end

  def comment_bodies(step)
    comments = step.diff.associations['comments']
    comments ? comments.changed.map { |change| change.attributes.fetch('body').to_h } : []
  end

  def titles(steps)
    steps.filter_map { |step| step.diff.attributes['title']&.to_h }
  end

  it 'reports only the steps of the events inside it' do
    article = TrackedArticle.create!(title: 'one')
    comment = article.comments.create!(body: 'before')
    start = now
    comment.update!(body: 'inside')
    finish = now
    comment.update!(body: 'after')
    article.update!(title: 'two')

    steps = timeline(article, within: start..finish)

    expect(steps.map { |step| comment_bodies(step) }).to eq([[{ from: 'before', to: 'inside' }]])
    expect(steps).to be_frozen
  end

  it 'reports and analyzes nothing when nothing changed inside it' do
    article = TrackedArticle.create!(title: 'one')
    comment = article.comments.create!(body: 'before')
    start = now
    finish = now
    comment.update!(body: 'after')

    steps = timeline(article, within: start..finish)
    result = analysis(article, within: start..finish)

    expect(steps).to eq([])
    expect(result.activity_timeline).to eq([])
    expect(result.timeline).to eq([])
    expect(result.diff).to be_empty
    expect([result.from_snapshot, result.to_snapshot]).to eq([nil, nil])
  end

  it 'reports and analyzes nothing without associations when the root did not change' do
    article = TrackedArticle.create!(title: 'one')
    start = now
    finish = now
    article.update!(title: 'two')

    steps = PaperTrailDiff.activity_timeline(article, within: start..finish)
    result = PaperTrailDiff.analyze(article, within: start..finish, activity: true)

    expect(steps).to eq([])
    expect([result.activity_timeline, result.timeline]).to eq([[], []])
    expect(result.diff).to be_empty
  end

  it 'selects a context version only when an association is asked for' do
    allow(PaperTrailDiff::RootVersionSelection).to receive(:new).and_call_original
    article = TrackedArticle.create!(title: 'one')
    window = now..now

    PaperTrailDiff.activity_timeline(article, within: window)
    PaperTrailDiff.activity_timeline(article, within: window, associations: [:comments])

    expect(PaperTrailDiff::RootVersionSelection).to have_received(:new)
      .with(hash_including(context_required: false)).once
    expect(PaperTrailDiff::RootVersionSelection).to have_received(:new)
      .with(hash_including(context_required: true)).once
  end

  it 'closes on the live row when nothing recorded follows it, read when it was built' do
    article = TrackedArticle.create!(title: 'one')
    comment = article.comments.create!(body: 'before')
    start = now
    article.update!(title: 'two')
    comment.update!(body: 'inside')
    before = now

    result = analysis(article, within: start..(now + 60))

    closing = result.activity_timeline.last
    expect(closing.to_boundary.kind).to eq(:current)
    expect(closing.to_boundary.recorded_at).to be_between(before, now)
    expect(closing.to_boundary.recorded_at).to be_utc
    expect(result.activity_timeline).to be_frozen
    expect(titles(result.timeline)).to eq([{ from: 'one', to: 'two' }])
    expect(result.timeline.last.to_boundary.recorded_at).to eq(closing.to_boundary.recorded_at)
    expect(result.to_snapshot.associations.fetch('comments').records
             .map { |record| record.attributes['body'] }).to eq(['inside'])
  end

  it 'analyzes up to the version after it, not to changes since' do
    article = TrackedArticle.create!(title: 'one')
    comment = article.comments.create!(body: 'before')
    start = now
    article.update!(title: 'two')
    finish = now
    article.update!(title: 'three')
    comment.update!(body: 'since')

    result = analysis(article, within: start..finish)

    expect(result.to_snapshot.attributes.fetch('title')).to eq('two')
    expect(result.to_snapshot.associations.fetch('comments').records
             .map { |record| record.attributes['body'] }).to eq(['before'])
  end

  it 'does not close on the live row after a change that followed it' do
    article = TrackedArticle.create!(title: 'one')
    comment = article.comments.create!(body: 'before')
    start = now
    comment.update!(body: 'inside')
    finish = now
    comment.update!(body: 'after')

    steps = timeline(article, within: start..finish)

    expect(steps.map { |step| comment_bodies(step) }).to eq([[{ from: 'before', to: 'inside' }]])
    expect(steps.last.to_boundary.kind).to eq(:version)
  end

  it 'closes on the destroy that ends it, from the destroyed state' do
    article = TrackedArticle.create!(title: 'one')
    start = now
    article.update!(title: 'two')
    article.reload.destroy!
    destroy = PaperTrail::Version.where(item_id: article.id, event: 'destroy').sole
    window = start..(now + 60)

    kept = timeline(article, within: window, snapshots: true, recorded_changes: true).last
    plain = timeline(article, within: window).last
    result = analysis(article, within: window)

    expect([kept.from_boundary.version_id, kept.from_boundary.event]).to eq([destroy.id, 'destroy'])
    expect([kept.to_boundary.kind, kept.to_boundary.version_id]).to eq([:destroyed, destroy.id])
    expect(kept.from_boundary.recorded_changes).not_to be_nil
    expect(kept.to_boundary.recorded_changes).not_to be_nil
    expect(kept.from_snapshot.attributes.fetch('title')).to eq('two')
    expect(kept.to_snapshot).to be_nil
    expect(plain.from_snapshot).to be_nil
    expect(result.to_snapshot).to be_nil
    expect(result.activity_timeline.last.to_boundary.kind).to eq(:destroyed)
  end

  it 'does not close on a destroy its filter leaves out' do
    article = TrackedArticle.create!(title: 'one')
    start = now
    PaperTrail.request(whodunnit: 'editor') { article.update!(title: 'two') }
    article.reload.destroy!
    editors = ->(versions) { versions.where(whodunnit: 'editor') }

    steps = timeline(article, within: start..(now + 60), version_scope: editors)

    expect(titles(steps)).to eq([{ from: 'one', to: 'two' }])
    expect(steps.map { |step| step.to_boundary.kind }).to eq([:version])
  end

  it 'closes on the live row after a child destroy, which ends nothing' do
    article = TrackedArticle.create!(title: 'one')
    comment = article.comments.create!(body: 'gone')
    start = now
    comment.destroy!

    steps = timeline(article, within: start..(now + 60))

    expect(steps.last.to_boundary.kind).to eq(:current)
  end

  it 'closes on the version its filter left out after the last kept one, not the live row' do
    article = TrackedArticle.create!(title: 'one')
    start = now
    PaperTrail.request(whodunnit: 'editor') { article.update!(title: 'kept') }
    article.update!(title: 'filtered')
    editors = ->(versions) { versions.where(whodunnit: 'editor') }

    steps = timeline(article, within: start..(now + 60), version_scope: editors)

    expect(titles(steps)).to eq([{ from: 'one', to: 'kept' }])
    expect(steps.map { |step| step.to_boundary.kind }.uniq).to eq([:version])
  end

  it 'ends a step at a child change saved with the version after it' do
    article = TrackedArticle.create!(title: 'one')
    comment = article.comments.create!(body: 'before')
    start = now
    comment.update!(body: 'inside')
    finish = now
    TrackedArticle.transaction do
      comment.update!(body: 'later')
      article.update!(title: 'two')
    end

    steps = timeline(article, within: start..finish)

    expect(steps.map { |step| [step.from_boundary.item_type, step.to_boundary.item_type] })
      .to eq([%w[TrackedComment TrackedComment]])
  end

  it 'refuses HABTM activity only when it has to close on the live row' do
    article = TrackedArticle.create!(title: 'one')
    start = now
    article.update!(title: 'two')
    finish = now
    options = { within: start..finish, associations: [:tags] }

    expect { PaperTrailDiff.activity_timeline(article, **options) }
      .to raise_error(PaperTrailDiff::UnsupportedLiveActivityError, /tags/)
    checkpoint(article)
    expect(titles(PaperTrailDiff.activity_timeline(article, **options)))
      .to eq([{ from: 'one', to: 'two' }])
  end

  it 'keeps the steps between versions frozen when it closes on the live row' do
    article = TrackedArticle.create!(title: 'one')
    from = article.versions.reorder(:created_at, :id).first
    article.update!(title: 'two')

    steps = timeline(article, from: from, to: article)

    expect(steps.last.to_boundary.kind).to eq(:current)
    expect(steps).to be_frozen
  end
end
