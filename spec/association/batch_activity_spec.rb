# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe 'batched activity reporting' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
    TrackedAuthor.delete_all
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
      within: (Time.now.utc - 3600)..(Time.now.utc + 60),
      associations: [:comments], activity: true, snapshots: true, group: :transaction
    }
    single = PaperTrailDiff.analyze(article, **options)
    batch = PaperTrailDiff.analyze_many([article], **options).values.fetch(0)
    scope = PaperTrailDiff.analyze_scope(TrackedArticle, limit: 1, **options)

    [batch, scope.analyses.values.fetch(0)].each do |result|
      expect(result.activity_timeline.map { |step| step.diff.to_h })
        .to eq(single.activity_timeline.map { |step| step.diff.to_h })
      last = result.activity_timeline.last
      expect(last.source_boundary.whodunnit).to eq('alice')
      expect(last.to_snapshot.attributes.fetch('title')).to eq('After')
      expect(last.diff.associations.fetch('comments').changed.first.attributes.fetch('body').to_h)
        .to eq(from: 'Before', to: 'After')
    end
  end

  # An author renamed under two articles is one version, decoded once, and
  # only when a step's changes are read.
  it 'decodes the changes a version recorded once for the batch, when first read' do
    author = TrackedAuthor.create!(name: 'Before')
    articles = Array.new(2) do |index|
      TrackedArticle.create!(title: "Article #{index}", author: author)
    end
    start = Time.now.utc
    author.update!(name: 'After')
    allow(PaperTrailDiff::RecordedChanges).to receive(:call).and_call_original

    analyses = PaperTrailDiff.analyze_many(articles, within: start..Time.now.utc,
                                                     associations: [:author], activity: true,
                                                     recorded_changes: true)
    expect(PaperTrailDiff::RecordedChanges).not_to have_received(:call)
    changes = analyses.values.map do |analysis|
      analysis.activity_timeline.flat_map(&:sources).map { |source| source.recorded_changes&.keys }
    end

    expect(changes).to eq([[%w[name]], [%w[name]]])
    expect(PaperTrailDiff::RecordedChanges).to have_received(:call).once
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
