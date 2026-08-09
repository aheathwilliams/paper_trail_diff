# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/documentation_examples'

RSpec.describe 'association documentation examples' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedReply.delete_all
    TrackedComment.delete_all
    TrackedProfile.delete_all
    TrackedAuthorship.delete_all
    TrackedArticle.delete_all
    TrackedAuthor.delete_all
    TrackedTag.delete_all
    stub_const('Article', TrackedArticle)
  end

  it 'executes association comparison and activity examples in one session' do
    context = Object.new.instance_eval { binding }
    context.local_variable_set(:article, Article.create!(title: 'Quickstart'))

    DocumentationExamples.evaluate(
      quickstart_path,
      session: 'quickstart-association',
      context: context
    )
    diff = context.local_variable_get(:diff)
    expect(diff.associations.fetch('comments').added.fetch(0).attributes.fetch('body'))
      .to eq('First comment')

    expect do
      DocumentationExamples.evaluate(
        quickstart_path,
        session: 'quickstart-activity',
        context: context
      )
    end.to output(/TrackedArticle #\d+\n/).to_stdout
    steps = context.local_variable_get(:steps)
    expect(steps.reject(&:empty?)).not_to be_empty
  end

  def quickstart_path
    File.expand_path('../../QUICKSTART.md', __dir__)
  end
end
