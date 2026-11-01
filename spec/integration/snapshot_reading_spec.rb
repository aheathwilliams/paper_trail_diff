# frozen_string_literal: true

require_relative '../support/core_database'

# The states the reference tells readers to take from an analysis.
RSpec.describe 'reading a state from an analysis' do
  before do
    PaperTrail::Version.delete_all
    CoreArticle.delete_all
  end

  it 'reads the record at one version from a range that starts there' do
    article = CoreArticle.create!(title: 'Draft', internal_note: 'n')
    article.update!(title: 'Review')
    article.update!(title: 'Published')
    version = article.versions.where(event: 'update').order(:id).last

    snapshot = PaperTrailDiff.analyze(article, from: version, to: article).from_snapshot

    expect(snapshot.attributes.fetch('title')).to eq('Review')
  end

  it 'begins a scoped window at the first change the filter keeps' do
    article = CoreArticle.create!(title: 'Draft', internal_note: 'n')
    start = Time.now.utc
    article.update!(title: 'System')
    PaperTrail.request(whodunnit: 'alice') { article.update!(title: 'Alice') }
    people = ->(versions) { versions.where.not(whodunnit: nil) }

    [false, true].each do |activity|
      analysis = PaperTrailDiff.analyze(article, within: start..Time.now.utc, version_scope: people,
                                                 activity: activity)
      expect(analysis.from_snapshot.attributes.fetch('title')).to eq('System')
    end
  end

  it 'has no start state for a record created inside, and the first step holds the created state' do
    start = Time.now.utc
    article = CoreArticle.create!(title: 'Draft', internal_note: 'n')
    article.update!(title: 'Later')

    analysis = PaperTrailDiff.analyze(article, within: start..Time.now.utc, activity: true,
                                               snapshots: true)

    expect(analysis.from_snapshot).to be_nil
    expect(analysis.activity_timeline.first.to_snapshot.attributes.fetch('title')).to eq('Draft')
  end
end
