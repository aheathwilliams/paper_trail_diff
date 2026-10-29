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

  it 'gives one row per field, with its record, change, and source, deleted records included' do
    article = actor('alice') { Article.create!(title: 'Draft') }
    comment = actor('bob') { article.comments.create!(body: 'First') }
    actor('carol') { article.update!(title: 'Published') }
    actor('dave') { comment.update!(body: 'Edited') }
    actor('erin') { comment.destroy! }
    gone = actor('frank') { Article.create!(title: 'Gone') }
    actor('frank') { gone.destroy! }

    article_id = identity(article)
    comment_id = identity(comment)
    gone_id = identity(gone)
    all_rows = recipe_rows
    shown = %w[title body]
    rows = all_rows.select { |row| shown.include?(row.fetch(:attribute)) }

    # author_id and reviewer_id stay blank throughout, so they have no rows.
    expect(all_rows.map { |row| row.fetch(:attribute) }.uniq)
      .to contain_exactly('body', 'created_at', 'title')
    expect(rows.map { |row| row.values_at(:root, :association, :record, :change) })
      .to eq([[article_id, '', article_id, :added],
              [article_id, 'comments', comment_id, :added],
              [article_id, '', article_id, :changed],
              [article_id, 'comments', comment_id, :changed],
              [article_id, 'comments', comment_id, :removed],
              [gone_id, '', gone_id, :added],
              [gone_id, '', gone_id, :removed]])
    expect(rows.map { |row| row.values_at(:attribute, :from, :to, :actor, :event) })
      .to eq([%w[title] + [nil, 'Draft', 'alice', 'create'],
              %w[body] + [nil, 'First', 'bob', 'create'],
              %w[title Draft Published carol update],
              %w[body First Edited dave update],
              %w[body Edited] + [nil, 'erin', 'destroy'],
              %w[title] + [nil, 'Gone', 'frank', 'create'],
              %w[title Gone] + [nil, 'frank', 'destroy']])
    expect(rows.first.fetch(:recorded_at)).to eq(article.versions.first.created_at)
  end
end
