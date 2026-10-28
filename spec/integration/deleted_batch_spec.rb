# frozen_string_literal: true

require_relative '../support/core_database'

RSpec.describe 'deleted root reporting' do
  before do
    PaperTrail::Version.delete_all
    CoreArticle.delete_all
  end

  def analyze(**options)
    PaperTrailDiff.analyze_scope(
      CoreArticle, limit: 20, within: (Time.now.utc - 3600)..(Time.now.utc + 60),
                   activity: true, snapshots: true, close_on: :current, include_deleted: true,
                   **options
    )
  end

  def seed_deleted(count)
    Array.new(count) do |index|
      article = CoreArticle.create!(title: "Deleted #{index}", internal_note: 'stable')
      article.update!(title: "Final #{index}")
      article.destroy!
      article
    end
  end

  def queries(&block)
    sql = []
    callback = lambda do |*args|
      payload = args.last
      sql << payload[:sql] unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    sql
  end

  it 'returns complete deleted activity and unavailable identities without live-row lookup' do
    deleted = seed_deleted(2)
    missing = CoreArticle.create!(title: 'No destroy', internal_note: 'stable')
    missing.delete

    result = analyze

    expect(result.roots).to be_empty
    expect(result.deleted.keys).to match_array(result.unreachable)
    expect(result.deleted.fetch(PaperTrailDiff::Endpoint.identity(missing))).to be_nil
    deleted.each_with_index do |article, index|
      analysis = result.deleted.fetch(PaperTrailDiff::Endpoint.identity(article))
      expect(analysis.activity_timeline.length).to eq(3)
      removal = analysis.activity_timeline.last
      expect(removal.to_snapshot).to be_nil
      expect(removal.from_snapshot.attributes.fetch('title')).to eq("Final #{index}")
      expect(removal.diff.record_presence_change.to).to be_nil
    end
    expect(result.deleted).to be_frozen
  end

  it 'keeps the query count flat as the missing population grows' do
    seed_deleted(1)
    one = queries { analyze }
    seed_deleted(5)
    six = queries { analyze }

    expect(six.length).to eq(one.length)
    expect(six.length).to be <= 6
  end

  it 'checks the combined population ceiling before reconstructing any state' do
    seed_deleted(2)
    CoreArticle.create!(title: 'Live', internal_note: 'stable')
    expect_any_instance_of(PaperTrail::Version).not_to receive(:reify)

    expect { analyze(limit: 2) }.to raise_error(PaperTrailDiff::BatchLimitExceededError)
  end

  it 'preserves the existing opt-in and destructuring contract' do
    seed_deleted(1)
    result = analyze(include_deleted: false)

    expect(result.deleted).to be_empty
    analyses, unreachable = result
    expect(analyses).to eq(result.analyses)
    expect(unreachable).to eq(result.unreachable)
  end

  it 'reports recent activity through now without requiring a PaperTrail closing option' do
    article = CoreArticle.create!(title: 'Before', internal_note: 'stable')
    article.update!(title: 'After')
    deleted = seed_deleted(1).first

    result = PaperTrailDiff.report(CoreArticle, since: Time.now.utc - 3600, limit: 5,
                                                include_deleted: true, snapshots: true)

    expect(result.analyses.values.first.activity_timeline.last.to_snapshot.attributes['title'])
      .to eq('After')
    expect(result.deleted.fetch(PaperTrailDiff::Endpoint.identity(deleted))).not_to be_nil
    expect { PaperTrailDiff.report(CoreArticle, since: Time.now.utc + 3600, limit: 5) }
      .to raise_error(PaperTrailDiff::InvalidTimeRangeError)
  end

  it 'applies historical filtering to the missing population before batch analysis' do
    seed_deleted(2)

    result = analyze(historical_filter: { title: 'Final 0' })

    expect(result.deleted.length).to eq(1)
    expect(result.deleted.values.first.activity_timeline.last.from_snapshot.attributes['title'])
      .to eq('Final 0')
  end
end
