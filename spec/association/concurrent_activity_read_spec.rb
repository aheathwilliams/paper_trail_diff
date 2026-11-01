# frozen_string_literal: true

require_relative '../support/association_database'

# A commit that lands while an activity read runs must not break it. Each
# statement of the read sees the same snapshot, so the late comment is in none.
RSpec.describe 'activity reads under a concurrent commit' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
  end

  def comment_bodies(snapshot)
    snapshot.associations.fetch('comments').records.map { |record| record.attributes['body'] }.sort
  end

  # The statement that reads a comment's full versions. The live comment rows
  # are read after it, so a comment committed here is missing from the versions.
  # MySQL inlines the item type into the SQL; PostgreSQL binds it.
  def reads_comment_versions?(payload)
    payload[:sql].match?(/\ASELECT [`"]versions[`"]\.\* FROM [`"]versions[`"]/) &&
      (payload[:sql].include?('TrackedComment') ||
        Array(payload[:type_casted_binds]).include?('TrackedComment'))
  end

  # Commits one comment on another connection, once, while the read runs.
  def commit_late_comment(article)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        TrackedComment.create!(article_id: article.id, body: 'late')
      end
    end.join
  end

  def read_with_late_comment(article)
    main = Thread.current
    fired = false
    callback = lambda do |*args|
      next if fired || Thread.current != main || !reads_comment_versions?(args.last)

      fired = true
      commit_late_comment(article)
    end
    steps = ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      PaperTrailDiff.activity_timeline(article, associations: [:comments],
                                                group: :transaction, snapshots: true)
    end
    [fired, steps]
  end

  it 'reads every statement from one snapshot, so a comment committed mid-read is in none' do
    adapter = TrackedArticle.connection_db_config.adapter
    skip 'needs a snapshot isolation level' unless %w[postgresql mysql2 trilogy].include?(adapter)

    article = TrackedArticle.create!(title: 'Article')
    article.comments.create!(body: 'before')

    fired, steps = read_with_late_comment(article)

    expect(fired).to be(true)
    expect(comment_bodies(steps.last.to_snapshot)).to eq(%w[before])
    expect(TrackedComment.where(article_id: article.id).pluck(:body))
      .to contain_exactly('before', 'late')
    later = PaperTrailDiff.activity_timeline(article, associations: [:comments],
                                                      group: :transaction, snapshots: true)
    expect(comment_bodies(later.last.to_snapshot)).to eq(%w[before late])
  end
end
