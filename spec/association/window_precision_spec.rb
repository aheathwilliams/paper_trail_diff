# frozen_string_literal: true

require_relative '../support/association_database'

# Adapters write a bound time to the microsecond, so a window edge finer than
# that selects versions in SQL as if cut there. Every check made in Ruby must
# cut it alike, or one method reports a version that another leaves out.
RSpec.describe 'a window edge finer than a microsecond' do
  let(:article) { TrackedArticle.create!(title: 'A') }
  let(:edited) do
    article.update!(title: 'B')
    article.versions.order(:id).last
  end
  # Half a microsecond after the edit: the same microsecond as the edit.
  let(:edge) { Time.at(edited.created_at.to_r + Rational(1, 2_000_000)).utc }

  def titles(steps)
    steps.map { |step| step.diff.attributes.fetch('title').to_h }
  end

  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedArticle.delete_all
    edited
    article.update!(title: 'C')
  end

  it 'starts the window at that microsecond in every method' do
    expected = [{ from: 'A', to: 'B' }, { from: 'B', to: 'C' }]

    expect(titles(SpecTimelines.timeline(article, within: edge..))).to eq(expected)
    expect(titles(SpecTimelines.activity_timeline(article, within: edge..))).to eq(expected)
    analysis = PaperTrailDiff.analyze_many([article], within: edge.., activity: true).values.sole
    expect(titles(analysis.activity_timeline)).to eq(expected)
  end

  it 'reads the edges cut to the microsecond' do
    range = PaperTrailDiff::TimeRange.new(edge..edge)

    expect([range.begin_time, range.end_time]).to eq([edited.created_at, edited.created_at])
    expect(range.include?(edited.created_at)).to be(true)
  end
end
