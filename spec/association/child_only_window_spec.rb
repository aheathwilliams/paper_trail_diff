# frozen_string_literal: true

require_relative '../support/association_database'

# Only a comment moves inside the window; the article itself has no version in
# it. The activity view must still report the comment, whether the window is
# closed by a later article version or by current state, and the single-record
# and batch forms must agree.
RSpec.describe 'Activity windows where only descendants changed' do
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

  it 'closes on current state when asked, attributing each comment event' do
    article, window_start = child_only_history

    steps = PaperTrailDiff.activity_timeline(
      article, within: window_start..Time.now.utc, associations: [:comments],
               close_on: :current
    ).reject(&:empty?)

    expect(steps.map { |step| step.source_boundary.item_type })
      .to eq(%w[TrackedComment TrackedComment])
    expect(steps.last.to_boundary.kind).to eq(:current)
  end

  it 'reports the same analysis singly and in a batch when closing on current state' do
    article, window_start = child_only_history
    options = { within: window_start..Time.now.utc, associations: [:comments],
                close_on: :current, activity: true }

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

  it 'closes on current state by default, as close_on: :current asks' do
    article, window_start = child_only_history
    window = window_start..Time.now.utc

    defaulted = PaperTrailDiff.activity_timeline(article, within: window, associations: [:comments])
    explicit = PaperTrailDiff.activity_timeline(
      article, within: window, associations: [:comments], close_on: :current
    )

    expect(defaulted.map { |step| step.diff.to_h }).to eq(explicit.map { |step| step.diff.to_h })
  end
end
