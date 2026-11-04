# frozen_string_literal: true

require_relative '../support/association_database'

# SQL Server writes the ids of a long list into the statement and compiles it
# afresh, in time that grows with their number, so the batch methods list ids
# Support::IDS_PER_STATEMENT at a time. Here that is two, against seven roots,
# three of them destroyed.
RSpec.describe 'Ids per statement in a batch' do
  let(:paths) { ['comments.replies', 'author'] }

  before do
    [PaperTrail::VersionAssociation, PaperTrail::Version, TrackedReply, TrackedComment,
     TrackedArticle, TrackedAuthor, TrackedTag].each(&:delete_all)
    ActiveRecord::Base.connection.execute('DELETE FROM tracked_articles_tags')
  end

  # The longest list of ids under each column that any statement holds.
  def longest_id_lists(&)
    quote = ActiveRecord::Base.connection.quote_column_name('x')
    longest = Hash.new(0)
    callback = lambda do |*, payload|
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])

      sql = payload[:sql].tr("#{quote[0]}#{quote[-1]}", '""')
      sql.scan(/"(\w*id)" IN \(([^()]*)\)/).each do |column, list|
        longest[column] = [longest[column], list.count(',') + 1].max
      end
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    longest
  end

  # Each article is tagged and then edited, so that activity on its tags,
  # which needs a version to end at, can read up to the edits. Returns the
  # articles and when the tagging ended.
  def history
    authors = Array.new(3) { |index| TrackedAuthor.create!(name: "Author #{index}") }
    articles = Array.new(7) do |index|
      article = TrackedArticle.create!(title: "Article #{index}", author: authors[index % 3])
      TrackedArticle.find(article.id).tags << TrackedTag.create!(name: "Tag #{index}")
      article.comments.create!(body: 'First').replies.create!(body: 'Reply')
      article
    end
    tagged = Time.now.utc
    articles.each do |article|
      article.update!(title: "#{article.title} edited")
      article.comments.first.update!(body: 'Edited')
    end
    articles.last(3).each(&:destroy!)
    [articles.first(4), tagged]
  end

  def view(analyses)
    analyses.transform_values do |analysis|
      steps = analysis&.activity_timeline || []
      [analysis&.diff&.to_h, steps.map { |step| [step.source_boundary.version_id, step.diff.to_h] }]
    end
  end

  def report(since)
    result = PaperTrailDiff.report(TrackedArticle, since: since, limit: 10, associations: paths,
                                                   include_deleted: true)
    [view(result.analyses), view(result.deleted)]
  end

  def firsts(articles)
    pairs = articles.map { |article| { from: :first, to: article } }
    PaperTrailDiff.compare_many(pairs, associations: paths).transform_values(&:to_h)
  end

  def tags(articles, within)
    view(PaperTrailDiff.analyze_many(articles, within: within, associations: [:tags],
                                               activity: true))
  end

  it 'lists ids two to a statement and reports the same' do
    since = Time.now.utc
    articles, tagged = history
    read = -> { [report(since), firsts(articles), tags(articles, since..tagged)] }
    expected = read.call
    stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 2)
    actual = nil

    longest = longest_id_lists { actual = read.call }

    expect(actual).to eq(expected)
    expect(longest.select { |_column, length| length > 2 }).to eq({})
    expect(longest.keys).to include('item_id', 'transaction_id', 'foreign_key_id', 'article_id')
  end
end
