# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe 'batched deleted association history' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
  end

  def seed(count)
    Array.new(count) do
      article = TrackedArticle.create!(title: 'Before')
      comment = article.comments.create!(body: 'Before')
      article.update!(title: 'After')
      comment.update!(body: 'After')
      article.destroy!
      article
    end
  end

  def report
    PaperTrailDiff.analyze_scope(
      TrackedArticle, limit: 10, within: (Time.now.utc - 3600)..(Time.now.utc + 60),
                      associations: [:comments], activity: true, snapshots: true,
                      include_deleted: true, close_on: :current
    )
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

  it 'matches single-root historical reconstruction without adding per-root queries' do
    articles = seed(1)
    one = queries { report }
    articles.concat(seed(4))
    result = nil
    five = queries { result = report }

    expect(five.length).to eq(one.length)
    articles.each do |article|
      root = article.versions.order(:id).last.reify
      expected = PaperTrailDiff.activity_timeline(
        root, within: (Time.now.utc - 3600)..(Time.now.utc + 60),
              associations: [:comments], snapshots: true
      )
      actual = result.deleted.fetch(PaperTrailDiff::Endpoint.identity(article)).activity_timeline
      expect(actual.map { |step| step.diff.to_h }).to eq(expected.map { |step| step.diff.to_h })
      comment = actual.last.from_snapshot.associations.fetch('comments').records.first
      expect(comment.attributes['body']).to eq('After')
      expect(actual.last.to_snapshot).to be_nil
    end
  end

  it 'keeps filter budgets and missing-history behavior with association tracking loaded' do
    seed(2)
    TrackedArticle.create!(title: 'No destroy').delete
    options = { since: Time.now.utc - 3600, limit: 10, include_deleted: true }

    result = PaperTrailDiff.report(TrackedArticle, **options, historical_filter: { title: 'After' })
    expect(result.deleted.length).to eq(2)
    expect(PaperTrailDiff.report(TrackedArticle, **options).deleted.values).to include(nil)
    expect do
      PaperTrailDiff.report(TrackedArticle, **options, historical_filter: {},
                                                       max_filter_versions: 1)
    end
      .to raise_error(PaperTrailDiff::FilterLimitExceededError)
    expect { PaperTrailDiff.report(TrackedArticle, **options, historical_filter: false) }
      .to raise_error(PaperTrailDiff::ConfigurationError)
    expect { PaperTrailDiff.report(TrackedArticle, **options, historical_filter: { absent: nil }) }
      .to raise_error(PaperTrailDiff::ConfigurationError)
    expect do
      PaperTrailDiff.report(TrackedArticle, **options, historical_filter: {},
                                                       max_filter_versions: nil)
    end
      .to raise_error(PaperTrailDiff::ConfigurationError)
    expect { PaperTrailDiff.report(TrackedArticle, **options, limit: 1) }
      .to raise_error(PaperTrailDiff::BatchLimitExceededError)
  end

  it 'also keeps live association activity queries flat across roots' do
    add = lambda do
      article = TrackedArticle.create!(title: 'Before')
      comment = article.comments.create!(body: 'First')
      3.times { |index| comment.update!(body: "Edit #{index}") }
      article.update!(title: 'After')
    end
    add.call
    one = queries { report }
    4.times { add.call }
    five = queries { report }

    expect(five.length).to eq(one.length)
    expect(report.analyses.values).to all(satisfy { |analysis|
      analysis.activity_timeline.length == 6
    })
  end

  it 'discovers through-association events from the prepared join population' do
    article = TrackedArticle.create!(title: 'Article')
    author = TrackedAuthor.create!(name: 'Before')
    TrackedAuthorship.create!(article: article, author: author, role: 'writer')
    author.update!(name: 'After')

    result = PaperTrailDiff.report(
      TrackedArticle.where(id: article.id), since: Time.now.utc - 3600, limit: 1,
                                            associations: [:contributors], snapshots: true
    )

    analysis = result.analyses.values.first
    contributors = analysis.to_snapshot.associations.fetch('contributors').records
    expect(contributors.map { |snapshot| snapshot.attributes['name'] }).to eq(['After'])
    expect(analysis.activity_timeline.map { |step| step.source_boundary.item_type })
      .to include('TrackedAuthor')
  end
end
