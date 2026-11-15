# frozen_string_literal: true

require_relative '../support/association_database'

# A has_one without a unique index can have two rows that name one owner.
# Active Record then reads one of them; history must read the same one, or a
# comparison with the current record reports a change that never happened.
# PostgreSQL promises no order for Active Record's LIMIT 1, so its current
# record can read either row (see docs/reference.md).
RSpec.describe 'a has_one with two rows for one owner' do
  let(:article) { TrackedArticle.create!(title: 'Article') }
  let(:first) { TrackedProfile.create!(article: article, bio: 'First') }

  before do
    skip 'PostgreSQL reads either row' if TrackedArticle.connection.adapter_name == 'PostgreSQL'

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
    timeline = SpecTimelines.timeline(article, associations: [:profile])
    activity = SpecTimelines.activity_timeline(article, associations: [:profile], snapshots: true)

    ids = activity.map { |step| step.to_snapshot.associations.fetch('profile').records.map(&:id) }
    expect(ids.last).to eq([first.id])
    expect(timeline.last.diff.associations).to be_empty
  end
end
