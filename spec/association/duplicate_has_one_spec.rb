# frozen_string_literal: true

require_relative '../support/association_database'

# A has_one without a unique index can have two rows that name one owner.
# Active Record then reads one of them; history must read the same one, or a
# comparison with the current record reports a change that never happened.
RSpec.describe 'a has_one with two rows for one owner' do
  let(:article) { TrackedArticle.create!(title: 'Article') }
  let(:first) { TrackedProfile.create!(article: article, bio: 'First') }

  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedProfile.delete_all
    TrackedArticle.delete_all
    first
    other = TrackedArticle.create!(title: 'Other')
    TrackedProfile.create!(article: other, bio: 'Second').update!(article: article)
    first.touch
    article.update!(title: 'Renamed')
  end

  it 'reads the row Active Record reads' do
    expect(article.reload.profile).to eq(first)

    diff = PaperTrailDiff.compare(article.versions.last, article, associations: [:profile])

    expect(diff.associations).to be_empty
  end

  it 'reads that row at every point, in timeline and activity alike' do
    timeline = PaperTrailDiff.timeline(article, associations: [:profile])
    activity = PaperTrailDiff.activity_timeline(article, associations: [:profile], snapshots: true)

    ids = activity.map { |step| step.to_snapshot.associations.fetch('profile').records.map(&:id) }
    expect(ids.last).to eq([first.id])
    expect(timeline.last.diff.associations).to be_empty
  end
end
