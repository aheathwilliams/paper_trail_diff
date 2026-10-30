# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/documentation_examples'

RSpec.describe 'README report rows recipe' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
    stub_const('Article', TrackedArticle)
  end

  def actor(name, &)
    PaperTrail.request(whodunnit: name, &)
  end

  def identity(record)
    PaperTrailDiff::Endpoint.identity(record)
  end

  def recipe_rows
    context = Object.new.instance_eval { binding }
    DocumentationExamples.evaluate(File.expand_path('../../README.md', __dir__),
                                   session: 'recipe-summary', context: context)
    context.local_variable_get(:rows)
  end

  def reference(record)
    { type: record.class.name, id: record.id }
  end

  it 'gives a row per field and per record, with its source, deleted records included' do
    article = actor('alice') { Article.create!(title: 'Draft') }
    comment = actor('bob') { article.comments.create!(body: 'First') }
    actor('carol') { article.update!(title: 'Published') }
    actor('dave') { comment.update!(body: 'Edited') }
    actor('erin') { comment.destroy! }
    gone = actor('frank') { Article.create!(title: 'Gone') }
    actor('frank') { gone.destroy! }

    all_rows = recipe_rows
    shown = [nil, 'title', 'body']
    rows = all_rows.select { |row| shown.include?(row.fetch(:attribute)) }

    # author_id and reviewer_id stay blank throughout, so they have no rows.
    expect(all_rows.map { |row| row.fetch(:attribute) }.uniq)
      .to contain_exactly(nil, 'body', 'created_at', 'title')
    expect(rows.map { |row| row.values_at(:root, :association_path, :record, :change) })
      .to eq([[identity(article), [], nil, :added],
              [identity(article), [], nil, :added],
              [identity(article), ['comments'], reference(comment), :added],
              [identity(article), ['comments'], reference(comment), :added],
              [identity(article), [], nil, :changed],
              [identity(article), ['comments'], reference(comment), :changed],
              [identity(article), ['comments'], reference(comment), :removed],
              [identity(article), ['comments'], reference(comment), :removed],
              [identity(gone), [], nil, :added],
              [identity(gone), [], nil, :added],
              [identity(gone), [], nil, :removed],
              [identity(gone), [], nil, :removed]])
    expect(rows.map { |row| row.values_at(:attribute, :from, :to, :whodunnit, :event) })
      .to eq([[nil, nil, nil, 'alice', 'create'], ['title', nil, 'Draft', 'alice', 'create'],
              [nil, nil, nil, 'bob', 'create'], ['body', nil, 'First', 'bob', 'create'],
              %w[title Draft Published carol update],
              %w[body First Edited dave update],
              [nil, nil, nil, 'erin', 'destroy'], ['body', 'Edited', nil, 'erin', 'destroy'],
              [nil, nil, nil, 'frank', 'create'], ['title', nil, 'Gone', 'frank', 'create'],
              [nil, nil, nil, 'frank', 'destroy'], ['title', 'Gone', nil, 'frank', 'destroy']])
    expect(rows.first.fetch(:recorded_at)).to eq(article.versions.first.created_at)
  end
end
