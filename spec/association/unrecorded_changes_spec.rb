# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/documentation_examples'

# PaperTrail stores a record's values before each change, so the result of a
# change is read from the record's next version, or from the current row when
# there is none. A write saved without a version in between is therefore part of
# the step for the record's previous recorded change, wherever it happens. These
# pin that rule, which the documentation states, and show that
# `recorded_changes` still tells the two apart.
RSpec.describe 'Changes saved without a version' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
  end

  def actor(name, &)
    PaperTrail.request(whodunnit: name, &)
  end

  # Alice creates the article and Bob a comment, whose body is then rewritten
  # without a version. Carol retitles the article, whose title is then rewritten
  # without a version too. Dave edits the comment last.
  def history
    article = actor('alice') { TrackedArticle.create!(title: 'Draft') }
    comment = actor('bob') { article.comments.create!(body: 'First') }
    comment.update_columns(body: 'Unrecorded body')
    actor('carol') { article.update!(title: 'Published') }
    article.update_columns(title: 'Unrecorded title')
    actor('dave') { comment.update!(body: 'Edited') }
    article
  end

  def steps_by_actor(steps)
    steps.to_h { |step| [step.source_boundary.whodunnit, step] }
  end

  def comment_diff(step)
    step.diff.associations.fetch('comments')
  end

  it "reports each unrecorded write in the step for that record's previous recorded change" do
    steps = steps_by_actor(PaperTrailDiff.activity_timeline(history, associations: [:comments]))

    expect(comment_diff(steps.fetch('bob')).added.map { |record| record.attributes.fetch('body') })
      .to eq(['Unrecorded body'])
    # The article's last version is Carol's, so the current row closes her step,
    # not the timeline's final step, which is Dave's.
    expect(steps.fetch('carol').diff.attributes.fetch('title').to_h)
      .to eq(from: 'Draft', to: 'Unrecorded title')
    expect(steps.fetch('dave').diff.attributes).to be_empty
    edits = comment_diff(steps.fetch('dave')).changed
    expect(edits.map { |change| change.attributes.fetch('body').to_h })
      .to eq([{ from: 'Unrecorded body', to: 'Edited' }])
  end

  it 'keeps an earlier unrecorded write when the range ends at a version' do
    article = history
    carol = article.versions.find_by!(whodunnit: 'carol')

    steps = steps_by_actor(
      PaperTrailDiff.activity_timeline(article, from: :first, to: carol, associations: [:comments])
    )

    expect(comment_diff(steps.fetch('bob')).added.map { |record| record.attributes.fetch('body') })
      .to eq(['Unrecorded body'])
  end

  it 'reports the same rule in the root timeline' do
    steps = steps_by_actor(PaperTrailDiff.timeline(history))

    expect(steps.fetch('carol').diff.attributes.fetch('title').to_h)
      .to eq(from: 'Draft', to: 'Unrecorded title')
  end

  it "reads only the event's own edit from recorded_changes" do
    article = history
    carol = article.versions.find_by!(whodunnit: 'carol')
    bob = PaperTrail::Version.find_by!(whodunnit: 'bob')

    expect(PaperTrailDiff.recorded_changes(carol).transform_values(&:to_h))
      .to eq('title' => { from: 'Draft', to: 'Published' })
    expect(PaperTrailDiff.recorded_changes(bob).fetch('body').to_h).to eq(from: nil, to: 'First')
  end

  it 'runs the reference example, reading every step source without a query' do
    article = history
    context = Object.new.instance_eval { binding }
    context.local_variable_set(:article, article)
    queries = Hash.new { |hash, key| hash[key] = [] }
    count = lambda do |key, &block|
      record_query = lambda do |*, payload|
        queries[key] << payload.fetch(:sql) unless payload[:name] == 'SCHEMA'
      end
      ActiveSupport::Notifications.subscribed(record_query, 'sql.active_record', &block)
    end

    count.call(:plain) { PaperTrailDiff.activity_timeline(article, associations: [:comments]) }
    results = count.call(:recorded) do
      DocumentationExamples.evaluate(
        File.expand_path('../../docs/reference.md', __dir__),
        session: 'reference-recorded-changes', context: context
      )
    end

    expect(results.last.transform_values(&:to_h))
      .to eq('body' => { from: 'Unrecorded body', to: 'Edited' })
    expect(context.local_variable_get(:steps).map { |step| step.source_boundary.whodunnit })
      .to eq(%w[alice bob carol dave])
    expect(queries.fetch(:recorded).size).to eq(queries.fetch(:plain).size)
  end

  it 'runs the reference example that lists every source with what it recorded' do
    article = history
    PaperTrail.request(whodunnit: 'erin') do
      TrackedArticle.transaction do
        article.update!(title: 'Final')
        article.comments.first.update!(body: 'Final')
      end
    end
    context = Object.new.instance_eval { binding }
    context.local_variable_set(:article, article)

    rows = DocumentationExamples.evaluate(
      File.expand_path('../../docs/reference.md', __dir__),
      session: 'reference-step-sources', context: context
    ).last

    expect(rows.map { |row| [row.fetch(:actor), row.fetch(:event), row.fetch(:record)[:type]] })
      .to eq([%w[alice create TrackedArticle], %w[bob create TrackedComment],
              %w[carol update TrackedArticle], %w[dave update TrackedComment],
              %w[erin update TrackedArticle], %w[erin update TrackedComment]])
    erin = rows.last(2)
    expect(erin.map { |row| row.fetch(:transaction_id) }.uniq.size).to eq(1)
    expect(erin.map { |row| row.fetch(:changes).transform_values(&:to_h) })
      .to eq([{ 'title' => { from: 'Unrecorded title', to: 'Final' } },
              { 'body' => { from: 'Edited', to: 'Final' } }])
  end
end
