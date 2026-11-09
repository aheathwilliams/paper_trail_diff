# frozen_string_literal: true

require_relative '../support/coarse_version_database'

# Active Record cuts a bound time to the precision of the column it is
# compared with, so a window edge finer than a version table's `created_at`
# selects versions in SQL as if cut there. Every check made in Ruby must cut
# it alike, or a version saved in the edge's second is in no window.
RSpec.describe 'a window edge finer than the version table keeps times' do
  let(:noon) { Time.utc(2026, 6, 1, 12) }
  let(:edge) { noon + Rational(7, 10) }
  let(:folder) { at(noon - 3600) { CoarseFolder.create!(title: 'draft') } }
  let(:page) { at(noon - 3600) { CoarsePage.create!(body: 'first', folder: folder) } }

  def at(time)
    callback = ->(version) { version.created_at = time }
    CoarseVersion.set_callback(:create, :before, callback, prepend: false)
    yield
  ensure
    CoarseVersion.skip_callback(:create, :before, callback)
  end

  def changes(steps)
    steps.flat_map { |step| step.change_rows.map { |row| [row.attribute, row.to] } }
  end

  def activity(window, associations: [:pages])
    PaperTrailDiff.analyze(folder.reload, within: window, activity: true,
                                          associations: associations).activity_timeline
  end

  before do
    CoarseVersion.delete_all
    CoarsePage.delete_all
    CoarseFolder.delete_all
    page
    at(noon) { folder.update!(title: 'published') }
    at(noon) { page.update!(body: 'edited') }
  end

  it 'reports a change saved in the second of the edge in exactly one window' do
    earlier = changes(activity((noon - 60)...edge))
    later = changes(activity(edge..))

    expect(earlier + later).to contain_exactly(%w[title published], %w[body edited])
  end

  it 'agrees with timeline about the window a root change is in' do
    steps = PaperTrailDiff.timeline(folder, within: edge..).length

    expect(activity(edge.., associations: []).length).to eq(steps)
  end

  it 'reports what it selects by the same edge' do
    report = PaperTrailDiff.report(CoarseFolder.all, since: edge, limit: 10, associations: [:pages])

    expect(report.analyses.values.map { |analysis| analysis.activity_timeline.length })
      .to all(be_positive)
  end

  it 'cuts the edges of a range to the digits it is given' do
    range = PaperTrailDiff::TimeRange.new(edge..edge, digits: 0)

    expect([range.begin_time, range.end_time]).to eq([noon, noon])
  end
end
