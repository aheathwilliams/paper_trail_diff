# frozen_string_literal: true

require_relative '../support/association_database'

# A record saved again under the id of one destroyed earlier, as saving
# `version.reify` restores it, is the same root before and after.
RSpec.describe 'A root restored after its destruction',
               mutant_expression: %w[PaperTrailDiff::ActivityTimelineBuilder
                                     PaperTrailDiff::ActivityTransactionGroups] do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedComment, TrackedArticle, TrackedAuthor].each(&:delete_all)
  end

  def rows(steps)
    steps.flat_map(&:change_rows).map do |row|
      [row.change, row.association_path.join('.'), row.attribute, row.source.version_id]
    end
  end

  # The removal is the destroy's own change, so the range that ends there
  # leaves it to the range that goes on to the restoring version.
  it 'reports its removal once in two ranges that meet at its destroy' do
    article = TrackedArticle.create!(title: 'draft')
    article.update!(title: 'published')
    article.destroy!
    article.versions.where(event: 'destroy').last.reify.save!
    article = TrackedArticle.find(article.id)
    article.update!(title: 'restored')
    first, _update, destroy = article.versions.reorder(:id).to_a
    steps = lambda do |**range|
      PaperTrailDiff.analyze(article, **range, associations: [:comments], activity: true)
                    .activity_timeline
    end

    split = rows(steps.call(from: first, to: destroy)) + rows(steps.call(from: destroy))

    expect(split.tally).to eq(rows(steps.call(from: first)).tally)
    expect(split.count do |change, path, attribute, _|
      [change, path, attribute] == [:removed, '', nil]
    end)
      .to eq(1)
  end

  it 'still ends a range at a destroy nothing follows with the removal' do
    article = TrackedArticle.create!(title: 'draft')
    destroy = article.tap(&:destroy!).versions.reorder(:id).last

    last = PaperTrailDiff.analyze(article, from: article.versions.reorder(:id).first, to: destroy,
                                           associations: [:comments], activity: true)
                         .activity_timeline.last

    expect(last.to_boundary).to be_destroyed
  end

  it 'reads nothing past a range that ends anywhere but a destroy' do
    article = TrackedArticle.create!(title: 'draft')
    article.update!(title: 'published')
    article.update!(title: 'final')
    first, update, = article.versions.reorder(:id).to_a
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] }

    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      PaperTrailDiff.analyze(article, from: first, to: update, associations: [:comments],
                                      activity: true)
    end

    expect(queries.grep(/"versions"."id" > /)).to eq([])
  end

  # The transaction that restores it is the root's from its first event, as
  # for a record created afresh, whichever window reads it.
  it 'credits the transaction that restores it alike in any window' do
    author = TrackedAuthor.create!(name: 'ann')
    article = TrackedArticle.create!(title: 'a', author: author)
    old = TrackedComment.create!(body: 'old', article: article)
    old.destroy!
    after_destroy = Time.now.utc
    before_restore = PaperTrail::Version.maximum(:id)
    comment = TrackedComment.transaction do
      author.update!(name: 'ann b')
      TrackedComment.create!(id: old.id, body: 'new', article: article)
    end
    credit = lambda do |start|
      steps = PaperTrailDiff.analyze(comment, within: start.., associations: ['article.author'],
                                              activity: true, group: :transaction).activity_timeline
      rows(steps).select do |_change, _path, attribute, source|
        attribute.nil? && source > before_restore
      end
    end

    expect(credit.call(author.created_at - 1)).to eq(credit.call(after_destroy))
    expect(credit.call(after_destroy).map(&:first)).to eq(%i[added added added])
  end
end
