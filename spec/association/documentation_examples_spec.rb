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

  it 'attributes each activity step to whoever made it, descendants included' do
    article = nil
    PaperTrail.request(whodunnit: 'Maya Chen') do
      article = Article.create!(title: 'Apollo Notes')
    end
    start_at = PaperTrail::Version.order(:id).first.created_at
    PaperTrail.request(whodunnit: 'Maya Chen') { article.update!(title: 'Apollo Notes v2') }
    # Priya only ever touches a descendant, which is exactly the case a root
    # `version_scope:` cannot report.
    PaperTrail.request(whodunnit: 'Priya Shah') do
      article.comments.create!(body: 'Needs a source for the launch date.')
    end
    PaperTrail.request(whodunnit: 'Maya Chen') { article.update!(title: 'Apollo Notes v3') }
    cutoff = PaperTrail::Version.order(:id).last.created_at
    # A window needs a later version to reveal what its final change produced.
    PaperTrail.request(whodunnit: 'Maya Chen') { article.update!(title: 'Apollo Notes v4') }

    context = Object.new.instance_eval { binding }
    context.local_variable_set(:article, article)
    context.local_variable_set(:window, start_at..cutoff)
    DocumentationExamples.evaluate(
      readme_path, session: 'readme-person-changes', context: context
    )

    by_priya = context.local_variable_get(:by_priya)
    expect(by_priya.length).to eq(1)
    expect(by_priya.fetch(0).from_boundary.whodunnit).to eq('Priya Shah')
    expect(by_priya.fetch(0).diff.associations.fetch('comments').added.length).to eq(1)
    expect(context.local_variable_get(:authors).keys).to contain_exactly('Maya Chen', 'Priya Shah')

    # The claim the section rests on: a root-version filter sees none of it.
    root_steps = PaperTrailDiff.timeline(
      article,
      within: start_at..cutoff,
      version_scope: ->(scope) { scope.where(whodunnit: 'Priya Shah') }
    )
    expect(root_steps).to be_empty
  end

  def quickstart_path
    File.expand_path('../../QUICKSTART.md', __dir__)
  end

  def readme_path
    File.expand_path('../../README.md', __dir__)
  end
end
