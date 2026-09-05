# frozen_string_literal: true

require_relative '../support/core_database'
require_relative '../support/documentation_examples'

RSpec.describe 'README reporting recipes' do
  before do
    PaperTrail::Version.delete_all
    DocumentationArticle.delete_all
    stub_const('Article', DocumentationArticle)
  end

  def run_recipe(name, context)
    DocumentationExamples.evaluate(File.expand_path('../../README.md', __dir__),
                                   session: name, context: context)
  end

  it 'compares the previous state with the current state using only the public API' do
    context = Object.new.instance_eval { binding }
    run_recipe('recipe-compare', context)

    expect(context.local_variable_get(:diff).attributes.fetch('title').to_h)
      .to eq(from: 'Draft', to: 'Published')
  end

  it 'reports creations and updates, inspects deletions, and names unrecoverable rows' do
    live = Article.create!(title: 'Before')
    live.update!(title: 'After')
    created = Article.create!(title: 'Created only')
    destroyed = Article.create!(title: 'Destroyed')
    destroyed.destroy!
    missing = Article.create!(title: 'Deleted without callbacks')
    missing.delete
    unversioned = PaperTrail.request(enabled: false) { Article.create!(title: 'No history') }
    context = Object.new.instance_eval { binding }

    run_recipe('recipe-report', context)
    run_recipe('recipe-deleted', context)
    report = context.local_variable_get(:report)
    expect(report.analyses.keys).to contain_exactly(
      PaperTrailDiff::Endpoint.identity(live), PaperTrailDiff::Endpoint.identity(created)
    )
    expect(report.analyses.fetch(PaperTrailDiff::Endpoint.identity(created)).activity_timeline.size)
      .to eq(1)
    deletion = context.local_variable_get(:deleted_activity)
                      .fetch(PaperTrailDiff::Endpoint.identity(destroyed)).last
    expect(deletion.to_boundary).to be_destroyed
    expect(deletion.diff.record_presence_change.to).to be_nil
    expect(context.local_variable_get(:unavailable)).to eq([PaperTrailDiff::Endpoint.identity(missing)])
    expect(PaperTrailDiff.analyze_many([unversioned]).values.first.diff).to be_empty
  end

  it 'returns an empty report when there is no history' do
    context = Object.new.instance_eval { binding }
    run_recipe('recipe-report', context)
    run_recipe('recipe-deleted', context)

    expect(context.local_variable_get(:rows)).to be_empty
    expect(context.local_variable_get(:deleted_activity)).to be_empty
    expect(context.local_variable_get(:unavailable)).to be_empty
  end
end
