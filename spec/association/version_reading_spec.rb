# frozen_string_literal: true

require_relative '../support/association_database'

# A version reads alike wherever it is used: an endpoint of `compare`, the end
# of one range and the start of the next. Each reads the records around it as
# they stood before every transaction that had not ended where the version's
# own took effect.
RSpec.describe 'One reading of a version' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedAuthorship, TrackedComment, TrackedArticle, TrackedAuthor].each(&:delete_all)
  end

  # Saves the block's versions as part of transaction `id`, as if they were
  # saved while other transactions were open.
  def in_transaction(id, whodunnit, &)
    saved = PaperTrail::Version.maximum(:id) || 0
    PaperTrail.request(whodunnit: whodunnit, &)
    PaperTrail::Version.where('id > ?', saved).update_all(transaction_id: 1_000_000 + id)
  end

  def bodies(snapshot)
    snapshot.associations.fetch('comments').records.map { |comment| comment.attributes['body'] }
  end

  def rows(steps)
    steps.flat_map(&:change_rows).select(&:attribute).map do |row|
      [row.change, [*row.association_path, row.attribute].join('.'), row.to,
       row.source.whodunnit]
    end
  end

  # A creates a comment and is still open when B saves the article; A ends
  # after it.
  def crossing_history
    article = TrackedArticle.create!(title: 'zero')
    article.update!(title: 'one')
    in_transaction(1, 'A') { article.comments.create!(body: 'hello') }
    in_transaction(2, 'B') { article.update!(title: 'two') }
    in_transaction(1, 'A') { TrackedAuthor.create!(name: 'done') }
    article.update!(title: 'three')
    article.reload
    _create, first, middle, last = article.versions.reorder(:id).to_a
    [article, first, middle, last]
  end

  it 'reports a change once when two ranges meet at a version, as the range over both does' do
    article, first, middle, last = crossing_history
    options = { associations: [:comments] }
    added = lambda do |from, to|
      rows(PaperTrailDiff.activity_timeline(article, from: from, to: to, **options))
        .select { |row| row[1] == 'comments.body' }
    end

    expect(added.call(first, last)).to eq([[:added, 'comments.body', 'hello', 'A']])
    expect(added.call(first, middle)).to eq([])
    expect(added.call(middle, last)).to eq([[:added, 'comments.body', 'hello', 'A']])
  end

  it 'reads a version alike in compare and at either end of a range' do
    article, first, middle, last = crossing_history
    options = { associations: [:comments] }

    expect(PaperTrailDiff.compare(first, middle, **options).associations).to eq({})
    ends = PaperTrailDiff.analyze(article, from: first, to: middle, activity: true, **options)
    starts = PaperTrailDiff.analyze(article, from: middle, to: last, activity: true, **options)
    expect([bodies(ends.to_snapshot), bodies(starts.from_snapshot)]).to eq([[], []])
    expect(PaperTrailDiff.compare(middle, last, **options).associations.fetch('comments')
                         .added.map { |comment| comment.attributes['body'] }).to eq(['hello'])
  end

  # B adds a comment and ends while A is open; A then saves the article.
  it 'does not report as its own another transaction that ended before a range began' do
    article = TrackedArticle.create!(title: 'one')
    comment = article.comments.create!(body: 'kept')
    in_transaction(1, 'A') { comment.update!(body: 'edited') }
    in_transaction(2, 'B') { article.comments.create!(body: 'added') }
    in_transaction(1, 'A') { article.update!(title: 'two') }
    from = article.versions.reorder(:id).last

    steps = PaperTrailDiff.activity_timeline(article.reload, from: from, associations: [:comments])

    expect(rows(steps)).to contain_exactly([:changed, 'title', 'two', 'A'],
                                           [:changed, 'comments.body', 'edited', 'A'])
  end

  # Without associations no other record is read, so nothing places a
  # version anywhere but where it was saved.
  it 'reports each version of the record alone where it was saved' do
    article = TrackedArticle.create!(title: 'one')
    start = Time.now.utc
    in_transaction(1, 'A') { article.update!(title: 'two') }
    edge = Time.now.utc
    in_transaction(1, 'A') { article.update!(title: 'three') }
    titles = lambda do |range|
      PaperTrailDiff.activity_timeline(article.reload, within: range)
                    .map { |step| step.diff.attributes.fetch('title').to }
    end

    expect([titles.call(start...edge), titles.call(edge..)]).to eq([%w[two], %w[three]])
  end

  describe 'a destroyed record' do
    it 'reports its destruction though a transaction that saved its tree before it ends later' do
      author = TrackedAuthor.create!(name: 'Ann')
      article = TrackedArticle.create!(title: 'Draft', author: author)
      start = Time.now.utc
      in_transaction(1, 'A') { author.update!(name: 'Anne') }
      in_transaction(2, 'B') { article.destroy! }
      in_transaction(1, 'A') { TrackedAuthor.create!(name: 'done') }
      gone = TrackedArticle.new(id: article.id)

      analysis = PaperTrailDiff.analyze(gone, within: start.., activity: true,
                                              associations: [:author])

      expect(analysis.to_snapshot).to be_nil
      expect(analysis.activity_timeline.map { |step| step.diff.record_presence_change&.to })
        .to eq([nil])
      expect(analysis.activity_timeline.last.to_boundary.kind).to eq(:destroyed)
    end

    it 'reports a change committed in its tree before the destroying transaction ended' do
      author = TrackedAuthor.create!(name: 'Ann')
      article = TrackedArticle.create!(title: 'Draft', author: author)
      start = Time.now.utc
      in_transaction(1, 'A') { article.destroy! }
      in_transaction(2, 'B') { author.update!(name: 'Anne') }
      edge = Time.now.utc
      in_transaction(1, 'A') { TrackedAuthor.create!(name: 'done') }
      gone = TrackedArticle.new(id: article.id)

      steps = PaperTrailDiff.activity_timeline(gone, within: start..edge, associations: [:author])

      expect(rows(steps)).to eq([[:changed, 'author.name', 'Anne', 'B']])
    end
  end

  # B adds a contributor and removes it again; A renames that author while
  # B is open and ends first. The join row was never committed.
  it 'does not read a join row created and destroyed in one transaction' do
    author = TrackedAuthor.create!(name: 'Ann')
    article = TrackedArticle.create!(title: 'one')
    authorship = nil
    in_transaction(2, 'B') do
      authorship = TrackedAuthorship.create!(article: article, author: author, role: 'writer')
    end
    in_transaction(1, 'A') { author.update!(name: 'Anne') }
    in_transaction(2, 'B') { authorship.destroy! }
    in_transaction(3, 'C') { article.update!(title: 'two') }

    steps = PaperTrailDiff.activity_timeline(article.reload, associations: [:contributors])

    expect(rows(steps).map(&:last).uniq).to eq([nil, 'C'])
    expect(steps.map { |step| step.diff.associations.keys }.flatten).to eq([])
  end

  describe 'version_scope in a report' do
    # B edits a comment and A saves a record outside the tree in the same
    # transaction. Activity keeps the transaction for A, so A's report
    # selects the article.
    it 'selects a record whose activity the filter keeps' do
      article = TrackedArticle.create!(title: 'one')
      comment = article.comments.create!(body: 'kept')
      since = Time.now.utc
      in_transaction(1, 'B') { comment.update!(body: 'edited') }
      in_transaction(1, 'A') { TrackedAuthor.create!(name: 'outside') }
      by_a = ->(scope) { scope.where(whodunnit: 'A') }

      steps = PaperTrailDiff.activity_timeline(article, within: since.., associations: [:comments],
                                                        version_scope: by_a)
      report = PaperTrailDiff.report(TrackedArticle.all, since: since, limit: 10,
                                                         associations: [:comments],
                                                         version_scope: by_a)

      expect(steps.length).to eq(1)
      expect(report.analyses.keys).to eq([['TrackedArticle', article.id.to_s]])
    end
  end
end
