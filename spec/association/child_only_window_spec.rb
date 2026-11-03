# frozen_string_literal: true

require_relative '../support/association_database'

# Only a comment moves inside the window; the article itself has no version in
# it. The activity view must still report the comment, whether the window is
# closed by a later article version or by current state, and the single-record
# and batch forms must agree.
RSpec.describe 'Activity windows where only descendants changed',
               mutant_expression: 'PaperTrailDiff::ActivityTimelineBuilder' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
  end

  def comment_summary(diff)
    comments = diff.associations.fetch('comments')
    {
      added: comments.added.map { |record| record.attributes.fetch('body') },
      changed: comments.changed.map { |change| change.attributes.fetch('body').to_h }
    }
  end

  def child_only_history
    article = TrackedArticle.create!(title: 'Root')
    comment = article.comments.create!(body: 'one')
    window_start = Time.now.utc
    comment.update!(body: 'two')
    article.comments.create!(body: 'added')
    [article, window_start]
  end

  def batch_analysis(article, options)
    PaperTrailDiff.analyze_many([article], **options)
                  .fetch(PaperTrailDiff::Endpoint.identity(article))
  end

  let(:expected) { { added: ['added'], changed: [{ from: 'one', to: 'two' }] } }

  it 'closes on current state, attributing each comment event' do
    article, window_start = child_only_history

    steps = PaperTrailDiff.activity_timeline(
      article, within: window_start..Time.now.utc, associations: [:comments]
    ).reject(&:empty?)

    expect(steps.map { |step| step.source_boundary.item_type })
      .to eq(%w[TrackedComment TrackedComment])
    expect(steps.last.to_boundary.kind).to eq(:current)
  end

  it 'reports the same analysis singly and in a batch when closing on current state' do
    article, window_start = child_only_history
    options = { within: window_start..Time.now.utc, associations: [:comments],
                activity: true }

    single = PaperTrailDiff.analyze(article, **options)
    batch = batch_analysis(article, options)

    expect(comment_summary(single.diff)).to eq(expected)
    expect(batch.diff.to_h).to eq(single.diff.to_h)
    expect(batch.activity_timeline.map { |step| step.diff.to_h })
      .to eq(single.activity_timeline.map { |step| step.diff.to_h })
  end

  it 'reports the same analysis singly and in a batch when a later version closes it' do
    article, window_start = child_only_history
    window_end = Time.now.utc
    TrackedArticle.transaction { TrackedArticle.find(article.id).paper_trail.save_with_version }
    options = { within: window_start..window_end, associations: [:comments], activity: true }

    single = PaperTrailDiff.analyze(article, **options)
    batch = batch_analysis(article, options)

    expect(comment_summary(single.diff)).to eq(expected)
    expect(batch.diff.to_h).to eq(single.diff.to_h)
  end

  # The article has no version after the window, but a comment does. The
  # window ends where it ends, so that later edit is in no step and not in the
  # window's final state, whichever method reads it.
  it 'ends a past window before an association change made after it' do
    article, window_start = child_only_history
    window = window_start..Time.now.utc
    TrackedComment.find_by!(body: 'two').update!(body: 'after the window')
    options = { within: window, associations: [:comments], activity: true }

    single = PaperTrailDiff.analyze(article, snapshots: true, **options)
    batch = batch_analysis(article, options)
    scoped = PaperTrailDiff.analyze_scope(TrackedArticle.all, limit: 10, **options)
                           .analyses.fetch(PaperTrailDiff::Endpoint.identity(article))
    steps = PaperTrailDiff.activity_timeline(article, within: window, associations: [:comments])

    expect(comment_summary(single.diff)).to eq(expected)
    expect(single.to_snapshot.associations.fetch('comments').records.map do |record|
      record.attributes.fetch('body')
    end).to contain_exactly('two', 'added')
    expect([batch.diff.to_h, scoped.diff.to_h]).to eq([single.diff.to_h] * 2)
    expect(steps.map { |step| step.to_boundary.kind }).not_to include(:current)
    expect(steps.flat_map { |step| comment_summary(step.diff)[:changed] })
      .to eq([{ from: 'one', to: 'two' }])
  end

  def statements(&)
    count = 0
    callback = ->(*args) { count += 1 unless %w[SCHEMA TRANSACTION].include?(args.last[:name]) }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    count
  end

  # Roots with no version in the window read their children's history from the
  # batch's preparation, as roots with versions there do, rather than one root
  # at a time.
  it 'prepares a batch of roots whose comments alone changed together' do
    articles = Array.new(5) do |index|
      article = TrackedArticle.create!(title: "Root #{index}")
      article.comments.create!(body: 'one')
      article
    end
    window_start = Time.now.utc
    articles.each { |article| article.comments.first.update!(body: 'two') }
    options = { within: window_start..Time.now.utc, associations: [:comments], activity: true }
    roots = articles.map { |article| TrackedArticle.find(article.id) }

    one = statements { PaperTrailDiff.analyze_many(roots.first(1), **options) }
    many = nil
    five = statements { many = PaperTrailDiff.analyze_many(roots, **options) }

    expect(five).to eq(one)
    roots.each do |root|
      single = PaperTrailDiff.analyze(root, **options)
      batch = many.fetch(PaperTrailDiff::Endpoint.identity(root))
      expect(batch.activity_timeline.map { |step| step.diff.to_h })
        .to eq(single.activity_timeline.map { |step| step.diff.to_h })
      expect(batch.diff.to_h).to eq(single.diff.to_h)
    end
  end
end
