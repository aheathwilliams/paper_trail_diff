# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/documentation_examples'

RSpec.describe 'README activity feed recipe' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
    stub_const('Article', TrackedArticle)
  end

  it 'reports one saved transaction with actor metadata and its changed children' do
    context = Object.new.instance_eval { binding }
    DocumentationExamples.evaluate(File.expand_path('../../README.md', __dir__),
                                   session: 'recipe-activity', context: context)
    feed = context.local_variable_get(:feed)
    saved = feed.select { |entry| entry.fetch(:actor) == 'alice' }

    expect(saved.size).to eq(1)
    changes = saved.first.fetch(:changes)
    expect(changes.fetch(:attributes).fetch('title')).to eq(from: 'Draft', to: 'Published')
    expect(changes.fetch(:associations).fetch('comments').fetch(:added).first
                  .fetch(:attributes).fetch('body')).to eq('Please review')
    expect(context.local_variable_get(:payload).last.fetch(:from).fetch(:whodunnit)).to eq('alice')
  end
end
