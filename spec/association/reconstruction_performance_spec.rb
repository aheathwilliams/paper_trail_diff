# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe 'bounded event reconstruction' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
  end

  def seed
    article = TrackedArticle.create!(title: 'Before')
    comment = article.comments.create!(body: 'Before')
    article.update!(title: 'After')
    comment.update!(body: 'After')
    article
  end

  def report
    PaperTrailDiff.report(TrackedArticle, since: Time.now.utc - 3600, limit: 10,
                                          associations: [:comments], snapshots: true)
  end

  def query_count
    count = 0
    callback = lambda do |*args|
      count += 1 unless %w[SCHEMA TRANSACTION].include?(args.last[:name])
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { report }
    count
  end

  it 'keeps child event queries flat without changesets and preserves their output' do
    seed
    expected = report.analyses.values.first
    PaperTrail::Version.update_all(object_changes: nil)
    expect_any_instance_of(PaperTrail::Version).not_to receive(:next)
    one = query_count
    actual = report.analyses.values.first

    expect(actual.activity_timeline.map { |step| step.diff.to_h })
      .to eq(expected.activity_timeline.map { |step| step.diff.to_h })
    expect(actual.to_snapshot.to_h).to eq(expected.to_snapshot.to_h)
    4.times { seed }
    PaperTrail::Version.update_all(object_changes: nil)
    expect(query_count).to eq(one)
  end

  def queries(comparisons)
    count = 0
    callback = ->(*args) { count += 1 unless %w[SCHEMA TRANSACTION].include?(args.last[:name]) }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      PaperTrailDiff.compare_many(comparisons, associations: [:profile])
    end
    count
  end

  # Active Record adds `limit(1)` to every has_one's association scope; only a
  # declared limit or offset needs loading per record.
  it 'loads a plain has_one of every current record together' do
    articles = []
    counts = [1, 4].map do |added|
      added.times do
        article = TrackedArticle.create!(title: 'Profiled')
        TrackedProfile.create!(article: article, bio: 'bio')
        articles << article
      end
      comparisons = articles.map { |article| { from: article.versions.first, to: article } }
      queries(comparisons)
    end

    expect(counts.last).to eq(counts.first)
  ensure
    TrackedProfile.delete_all
  end

  # Through activity after a root's last version reads the root's current
  # row, which the batch has already loaded.
  it "reads each root's current row once in a report with through activity" do
    counts = [1, 4].map do |added|
      added.times do
        article = seed
        TrackedAuthorship.create!(article: article, author: TrackedAuthor.create!(name: 'A'),
                                  role: 'writer')
      end
      report_queries(%i[contributors])
    end

    expect(counts.last).to eq(counts.first)
  ensure
    TrackedAuthorship.delete_all
    TrackedAuthor.delete_all
  end

  def report_queries(associations)
    count = 0
    callback = ->(*args) { count += 1 unless %w[SCHEMA TRANSACTION].include?(args.last[:name]) }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      PaperTrailDiff.report(TrackedArticle, since: Time.now.utc - 3600, limit: 10,
                                            associations: associations)
    end
    count
  end

  it 'uses handled absence without asking a version for a successor or live row' do
    version = instance_double(PaperTrail::Version, event: 'update')
    resolver = PaperTrailDiff::ActivityEventRecordResolver.new(
      prepared_record_after: ->(_version) { [true, nil] }
    )

    expect(resolver.record_after(version)).to be_nil
  end

  it 'normalizes plain checkpoint graphs without historical AR instances' do
    3.times { seed }
    expect_any_instance_of(PaperTrail::Version).not_to receive(:reify)
    expect_any_instance_of(PaperTrailDiff::PreparedRecordState).not_to receive(:instantiate)

    result = PaperTrailDiff.analyze_scope(
      TrackedArticle, within: (Time.now.utc - 3600)..Time.now.utc, limit: 10,
                      close_on: :current, associations: [:comments]
    )

    expect(result.analyses.length).to eq(3)
    expect(result.analyses.values.map do |analysis|
      analysis.to_snapshot.associations.fetch('comments').records.first.attributes.fetch('body')
    end).to eq(['After'] * 3)
  end

  it 'normalizes plain scalar activity without reifying roots or leaf children' do
    3.times { seed }
    expect_any_instance_of(PaperTrail::Version).not_to receive(:reify)
    expect_any_instance_of(PaperTrailDiff::PreparedRecordState).not_to receive(:instantiate)

    expect(report.analyses.length).to eq(3)
  end

  it 'distinguishes an unknown version from known absence in the prepared index' do
    article = seed
    version = article.versions.order(:id).last
    series = PaperTrailDiff::PreparedRecordSeries.new(versions: [version], live: nil)

    expect(series.record_after(version)).to eq([true, nil])
    expect(series.record_after(instance_double(PaperTrail::Version, id: -1))).to eq([false, nil])
  end

  it 'discovers belongs-to identities without constructing historical owners' do
    author = TrackedAuthor.create!(name: 'Author')
    3.times { seed.update!(author: author) }
    expect_any_instance_of(PaperTrail::Version).not_to receive(:reify)
    expect_any_instance_of(PaperTrailDiff::PreparedRecordState).not_to receive(:instantiate)

    result = PaperTrailDiff.report(TrackedArticle, since: Time.now.utc - 3600,
                                                   limit: 10, associations: [:author])
    expect(result.analyses.length).to eq(3)
  end
end
