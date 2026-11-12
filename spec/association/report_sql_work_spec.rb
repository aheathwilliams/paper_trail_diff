# frozen_string_literal: true

require_relative '../support/association_database'

# A report's SQL may read its window a few times, but never once for each of
# its roots' versions. A plan that does passes every other spec and shows
# only at scale: a subquery correlated with each version before a window's
# start, which SQLite answered through the type-and-time index, took a report
# of 10,000 articles from 6 to 44 ms an article.
#
# SQLite counts the steps its virtual machine takes for each statement, the
# same on every run for the same data, plan, and SQLite version, where a time
# is not. Each SELECT the report ran is run again on its own to count it, so
# the count does not depend on what the adapter caches. The plans depend on
# the indexes, so the README's are in place, and the comments' foreign key
# has one, as `t.references` gives it.
RSpec.describe 'The SQL work of a report with associations' do
  let(:indexes) do
    {
      'index_versions_on_item_and_timeline' => [:versions, %i[item_type item_id created_at id]],
      'index_versions_on_type_and_time' => [:versions, %i[item_type created_at item_id]],
      'index_tracked_comments_on_article_id' => [:tracked_comments, %i[article_id]]
    }
  end

  before do
    skip 'counts SQLite statements' unless ActiveRecord::Base.connection.adapter_name == 'SQLite'

    # Every other version table the suite defines would be checked for
    # transactions numbered alike, in each statement that reads a transaction.
    allow(ActiveRecord::Base).to receive(:descendants).and_return([PaperTrail::Version])
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedComment, TrackedArticle].each(&:delete_all)
    indexes.each do |name, (table, columns)|
      ActiveRecord::Base.connection.add_index(table, columns, name: name)
    end
  end

  after do
    connection = ActiveRecord::Base.connection
    indexes.each do |name, (table, _)|
      connection.remove_index(table, name: name) if connection.index_name_exists?(table, name)
    end
  end

  # Articles each created with four comments in one transaction, then edited
  # with one of them in another, inside the window.
  def history(count)
    articles = Array.new(count) do |index|
      TrackedArticle.transaction do
        TrackedArticle.create!(title: "Article #{index}").tap do |article|
          4.times { |comment| article.comments.create!(body: "Comment #{comment}") }
        end
      end
    end
    start = Time.now.utc
    articles.each do |article|
      TrackedArticle.transaction do
        article.update!(title: "#{article.title}!")
        article.comments.first.update!(body: 'Edited')
      end
    end
    [articles, start]
  end

  # Other articles, each with a comment, and for each a version of the one or
  # the other, two in three of the comment, in a transaction of its own, with
  # the association rows PT-AT writes for it: a quarter before the window and
  # the rest inside it. They are written in bulk, as saving thousands would
  # take seconds, and their transactions are negative, so none is a real one.
  def other_history(range, start)
    articles = insert(TrackedArticle, range.map { |index| { title: "Other #{index}" } }, :title)
    comments = insert(TrackedComment, articles.map { |title, id| { body: title, article_id: id } },
                      :article_id)
    versions = range.map do |index|
      article = articles.fetch("Other #{index}")
      comment = index % 3 != 2
      offset = Rational((index / 4) + 1, 1_000_000)
      { item_type: comment ? 'TrackedComment' : 'TrackedArticle', event: 'update',
        item_id: comment ? comments.fetch(article) : article, transaction_id: -1 - index,
        created_at: (index % 4).zero? ? start - offset : start + offset }
    end
    PaperTrail::Version.insert_all!(versions)
    associate(versions, comments.invert)
  end

  # Inserts the rows, and returns each one's id keyed by its `key` column.
  def insert(model, rows, key)
    now = Time.now.utc
    model.insert_all!(rows.map { |row| row.merge(created_at: now, updated_at: now) })
    model.where(key => rows.map { |row| row.fetch(key) }).pluck(key, :id).to_h
  end

  # What PT-AT writes for each version: a comment's article and reviewer, or
  # an article's author.
  def associate(versions, article_of)
    saved = PaperTrail::Version.where(transaction_id: versions.map { |row| row[:transaction_id] })
    rows = saved.pluck(:id, :item_type, :item_id).flat_map do |id, type, item|
      links = if type == 'TrackedComment'
                [['article_id', article_of.fetch(item), 'TrackedArticle'],
                 ['reviewer_id', nil, 'TrackedAuthor']]
              else
                [['author_id', nil, 'TrackedAuthor']]
              end
      links.map do |name, target, target_type|
        { version_id: id, foreign_key_name: name, foreign_key_id: target,
          foreign_type: target_type }
      end
    end
    PaperTrail::VersionAssociation.insert_all!(rows)
  end

  # Each SELECT the block runs, with the steps SQLite takes to run it again.
  def sql_work(&)
    statements = []
    collect = lambda do |*, payload|
      sql = payload[:sql]
      next if payload[:name] == 'SCHEMA' || !sql.lstrip.match?(/\A(?:SELECT|WITH)\b/i)

      binds = payload[:type_casted_binds]
      statements << [sql, binds.respond_to?(:call) ? binds.call : binds]
    end
    ActiveSupport::Notifications.subscribed(collect, 'sql.active_record', &)
    statements.map { |sql, binds| [steps(sql, binds), sql] }
  end

  def steps(sql, binds)
    statement = ActiveRecord::Base.connection.raw_connection.prepare(sql)
    statement.bind_params(binds) unless binds.nil? || binds.empty?
    statement.execute.to_a
    statement.stat(:vm_steps)
  ensure
    statement&.close
  end

  # The statements whose work grew the most from one count to the next.
  def growth(before, after)
    earlier = by_statement(before)
    by_statement(after).map { |sql, steps| [steps - earlier.fetch(sql, 0), sql] }
                       .max_by(3, &:first)
                       .map { |grew, sql| "+#{grew} steps: #{sql.gsub(/\s+/, ' ')[0, 300]}" }
  end

  def by_statement(work)
    work.group_by(&:last).transform_values { |runs| runs.sum(&:first) }
  end

  # Each version of another record took the report 45 more steps when this
  # was written, and 380 when a statement read the window's later comment
  # versions again for each version the roots saved before it.
  it "reads other records' versions a few times, not once for each root version" do
    articles, start = history(24)
    scope = TrackedArticle.where(id: articles.map(&:id))
    options = { since: start, limit: 24, associations: [:comments] }
    report = -> { sql_work { PaperTrailDiff.report(scope, **options) } }
    other_history(0...1_000, start)
    before = report.call
    other_history(1_000...2_000, start)
    after = report.call

    grew = after.sum(&:first) - before.sum(&:first)
    expect(grew.fdiv(1_000)).to be <= 100,
                                -> { "#{grew} more steps:\n#{growth(before, after).join("\n")}" }
  end
end
