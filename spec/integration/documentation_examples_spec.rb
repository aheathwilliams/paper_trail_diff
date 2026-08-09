# frozen_string_literal: true

require_relative '../support/core_database'
require_relative '../support/documentation_examples'

RSpec.describe 'core documentation examples' do
  before do
    PaperTrail::Version.delete_all
    DocumentationArticle.delete_all
    stub_const('Article', DocumentationArticle)
  end

  def documentation_binding
    Object.new.instance_eval { binding }
  end

  def run_quickstart(session, context)
    DocumentationExamples.evaluate(
      quickstart_path,
      session: session,
      context: context
    )
  end

  it 'executes the basic quickstart as one stateful console session' do
    context = documentation_binding

    run_quickstart('quickstart-history', context)
    expect(context.local_variable_get(:draft_version).reify.title).to eq('Draft')
    expect(context.local_variable_get(:published_version).reify.title).to eq('Published')

    run_quickstart('quickstart-compare', context)
    expect(context.local_variable_get(:diff).to_h).to eq(
      record_presence_change: nil,
      attributes: { 'title' => { from: 'Draft', to: 'Published' } },
      associations: {}
    )

    run_quickstart('quickstart-current', context)
    expect(context.local_variable_get(:diff).attributes.fetch('title').to_h)
      .to eq(from: 'Published', to: 'Final')

    run_quickstart('quickstart-timeline-state', context)
    run_quickstart('quickstart-timeline', context)
    expect(documented_title_changes(context)).to eq(
      [%w[Draft Published], %w[Published Final]]
    )

    ignore_results = run_quickstart('quickstart-ignore', context)
    expect(ignore_results.last.attributes.keys)
      .to include('title', 'updated_at')
  end

  it 'executes the README traversal examples against a nested result' do
    reply = PaperTrailDiff::RecordSnapshot.new(
      type: 'Reply', id: 7, attributes: { body: 'Included' }
    )
    comment = PaperTrailDiff::RecordSnapshot.new(
      type: 'Comment',
      id: 3,
      attributes: { body: 'Added' },
      associations: {
        replies: PaperTrailDiff::AssociationSnapshot.new(
          kind: :has_many,
          records: [reply]
        )
      }
    )
    from = PaperTrailDiff::RecordSnapshot.new(type: 'Article', id: 1, attributes: {})
    to = PaperTrailDiff::RecordSnapshot.new(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: {
        comments: PaperTrailDiff::AssociationSnapshot.new(
          kind: :has_many,
          records: [comment]
        )
      }
    )
    context = documentation_binding
    context.local_variable_set(:diff, PaperTrailDiff::Engine.compare(from, to))

    DocumentationExamples.evaluate(
      readme_path,
      session: 'readme-traversal-changes',
      context: context
    )
    DocumentationExamples.evaluate(
      readme_path,
      session: 'readme-traversal-entries',
      context: context
    )

    expect(context.local_variable_get(:counts)).to eq(record_added: 1)
  end

  def documented_title_changes(context)
    context.local_variable_get(:steps).map do |step|
      change = step.diff.attributes.fetch('title')
      [change.from, change.to]
    end
  end

  def quickstart_path
    File.expand_path('../../QUICKSTART.md', __dir__)
  end

  def readme_path
    File.expand_path('../../README.md', __dir__)
  end
end
