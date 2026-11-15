# frozen_string_literal: true

require_relative '../support/association_database'

# A row older than its history has no versions, which reads as an empty
# analysis alone and in a batch alike.
RSpec.describe 'A batch over whole histories with a root that has no versions' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedComment, TrackedArticle, TrackedAuthor].each(&:delete_all)
  end

  it 'reports nothing for that root, and reads the others' do
    author = TrackedAuthor.create!(name: 'Ann')
    older = PaperTrail.request(enabled: false) do
      TrackedArticle.create!(title: 'Old', author: author)
    end
    recent = TrackedArticle.create!(title: 'New', author: author)
    recent.update!(title: 'New, edited')
    options = { associations: [:comments], activity: true }

    alone = PaperTrailDiff.analyze(older, **options)
    batch = PaperTrailDiff.analyze_many([older, recent], **options)

    expect(alone.timeline).to be_empty
    expect(batch.fetch(PaperTrailDiff::Endpoint.identity(older)).timeline).to be_empty
    expect(batch.fetch(PaperTrailDiff::Endpoint.identity(older)).activity_timeline).to be_empty
    expect(batch.fetch(PaperTrailDiff::Endpoint.identity(recent)).diff.to_h)
      .to eq(PaperTrailDiff.analyze(recent, **options).diff.to_h)
  end
end
