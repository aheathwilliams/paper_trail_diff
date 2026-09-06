# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe 'batched activity reporting' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
  end

  it 'groups saves and retains snapshots consistently across single, batch, and scope calls' do
    article = TrackedArticle.create!(title: 'Before')
    comment = article.comments.create!(body: 'Before')
    PaperTrail.request(whodunnit: 'alice') do
      TrackedArticle.transaction do
        article.update!(title: 'After')
        comment.update!(body: 'After')
      end
    end
    options = {
      within: (Time.now.utc - 3600)..(Time.now.utc + 60), close_on: :current,
      associations: [:comments], activity: true, snapshots: true, group: :transaction
    }
    single = PaperTrailDiff.analyze(article, **options)
    batch = PaperTrailDiff.analyze_many([article], **options).values.fetch(0)
    scope = PaperTrailDiff.analyze_scope(TrackedArticle, limit: 1, **options)
    alias_result = PaperTrailDiff.analyze_many(scope: TrackedArticle, limit: 1, **options)

    [batch, scope.analyses.values.fetch(0), alias_result.analyses.values.fetch(0)].each do |result|
      expect(result.activity_timeline.map { |step| step.diff.to_h })
        .to eq(single.activity_timeline.map { |step| step.diff.to_h })
      last = result.activity_timeline.last
      expect(last.source_boundary.whodunnit).to eq('alice')
      expect(last.to_snapshot.attributes.fetch('title')).to eq('After')
      expect(last.diff.associations.fetch('comments').changed.first.attributes.fetch('body').to_h)
        .to eq(from: 'Before', to: 'After')
    end
  end

  it 'does not report descendant events outside a closed reporting window' do
    article = TrackedArticle.create!(title: 'Before')
    comment = article.comments.create!(body: 'Before')
    start_at = Time.now.utc
    article.update!(title: 'Inside')
    comment.update!(body: 'Inside')
    cutoff = PaperTrail::Version.order(:id).last.created_at
    comment.update!(body: 'Outside')
    article.update!(title: 'Trailing checkpoint')
    options = { within: start_at..cutoff, associations: [:comments], activity: true }
    single = PaperTrailDiff.analyze(article, **options)
    batch = PaperTrailDiff.analyze_many([article], **options).values.first

    expect(batch.activity_timeline.map { |step| step.diff.to_h })
      .to eq(single.activity_timeline.map { |step| step.diff.to_h })
    expect(batch.activity_timeline.map { |step| step.source_boundary.recorded_at })
      .to all(be <= cutoff)
  end
end
