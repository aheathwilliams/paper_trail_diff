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
  # From two records on: a batch ends at its last root version, and a lone
  # article's profile, created after that, is not read from history at all.
  it 'loads a plain has_one of every current record together' do
    articles = []
    counts = [2, 4].map do |added|
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
                      associations: [:comments]
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

  # A root that changed only before the window starts from its current row,
  # which is read with prepared history as a version is.
  it 'normalizes a root that starts from its current row without historical AR instances' do
    articles = Array.new(3) { TrackedArticle.create!(title: 'Root') }
    comments = articles.map { |article| article.comments.create!(body: 'Before') }
    start = Time.now.utc
    comments.each { |comment| comment.update!(body: 'After') }
    expect_any_instance_of(PaperTrailDiff::PreparedRecordState).not_to receive(:instantiate)

    result = PaperTrailDiff.analyze_scope(TrackedArticle, within: start..Time.now.utc, limit: 10,
                                                          activity: true, associations: [:comments])

    bodies = result.analyses.values.map do |analysis|
      analysis.activity_timeline.map do |step|
        changes = step.diff.associations.fetch('comments').changed
        changes.map { |change| change.attributes.fetch('body').to_h }
      end
    end
    expect(bodies).to eq([[[{ from: 'Before', to: 'After' }]]] * 3)
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

  # A root whose window holds `count` transactions, each changing two comments.
  def grouped_history(count)
    article = TrackedArticle.create!(title: 'Root')
    comments = Array.new(2) { |index| article.comments.create!(body: "comment #{index}") }
    start = Time.now.utc
    count.times do |index|
      TrackedArticle.transaction { comments.each { |comment| comment.update!(body: index.to_s) } }
    end
    [TrackedArticle.find(article.id), start..Time.now.utc]
  end

  # Statements that read the root's table while that root's activity is read.
  def root_reads(count)
    root, window = grouped_history(count)
    reads = 0
    callback = ->(*args) { reads += 1 if args.last[:sql].include?('tracked_articles') }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      PaperTrailDiff.analyze(root, within: window, associations: [:comments], activity: true)
    end
    reads
  end

  # A transaction's changes are read again as a branch of the snapshot that
  # starts from the current record; each such snapshot copies one read of it.
  # Preparation reads them for its edges, and activity then reads the same
  # rows to find its events. The patterns pass any adapter's quoting.
  it "reads the owners' children once for preparation and activity alike" do
    3.times { seed }
    sqls = []
    callback = ->(*args) { sqls << args.last[:sql] }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      PaperTrailDiff.analyze_many(TrackedArticle.all.to_a,
                                  within: (Time.now.utc - 3600)..Time.now.utc,
                                  associations: [:comments], activity: true)
    end

    expect(sqls.grep(/version_associations/).length).to eq(1)
    expect(sqls.grep(/tracked_comments\W*\.\W*article_id\W*,/).length).to eq(1)
  end

  it 'reads the current root once however many snapshots start from it' do
    expect(root_reads(4)).to eq(root_reads(1))
  end

  # After the article's last edit, the snapshots start from its current row:
  # the one at the comment edited in the same transaction, carried from the
  # article's, and the one at the other comment's edit, rebuilt once that
  # transaction ends. Both start from one state of the row, read from the
  # record the call loaded.
  it "reads the current article's state once for every snapshot that starts from it" do
    article = TrackedArticle.create!(title: 'Draft')
    comments = Array.new(2) { |index| article.comments.create!(body: "comment #{index}") }
    start = Time.now.utc
    TrackedArticle.transaction do
      article.update!(title: 'Edited')
      comments.first.update!(body: 'edited')
    end
    comments.last.update!(body: 'edited')
    read = 0
    allow(PaperTrailDiff::PreparedRecordState).to receive(:new).and_wrap_original do |new, record|
      read += 1 if record.is_a?(TrackedArticle)
      new.call(record)
    end

    analysis = PaperTrailDiff.analyze(TrackedArticle.find(article.id), within: start..Time.now.utc,
                                                                       associations: [:comments],
                                                                       activity: true)

    expect(read).to eq(1)
    expect(analysis.diff.attributes.fetch('title').to_h).to eq(from: 'Draft', to: 'Edited')
    expect(analysis.diff.associations.fetch('comments').changed.map { |change| change.record.id })
      .to match_array(comments.map(&:id))
  end

  # PT-AT reads what a transaction saved as it stood before the transaction
  # began, so after a comment's event the next event of the same transaction
  # reads the same state. The article's snapshot is built for its own event and
  # the one after it, not again for each comment.
  it 'builds the snapshot of a transaction once after its first comment' do
    article = TrackedArticle.transaction do
      TrackedArticle.create!(title: 'Draft').tap do |created|
        3.times { |index| created.comments.create!(body: "Comment #{index}") }
      end
    end
    comments = article.comments.order(:id).to_a
    first = article.versions.reorder(:created_at, :id).first
    expect_any_instance_of(PaperTrailDiff::PreparedActivitySnapshots)
      .to receive(:call).twice.and_call_original

    steps = SpecTimelines.activity_timeline(article, from: first, to: article,
                                                     associations: [:comments])

    reported = steps.reject(&:empty?)
    expect(reported.map { |step| step.source_boundary.item_id })
      .to eq([article.id, comments.last.id])
    expect(reported.last.diff.associations.fetch('comments').added.map(&:id))
      .to match_array(comments.map(&:id))
  end

  # Counts the snapshots read from history while a timeline is built: whole
  # ones, which the first event and the closing state each take, and
  # branches read again for a snapshot carried forward.
  def snapshot_reads
    reads = { whole: 0, branches: 0 }
    allow_any_instance_of(PaperTrailDiff::PreparedActivitySnapshots)
      .to receive(:call).and_wrap_original do |original, *arguments|
        reads[:whole] += 1
        original.call(*arguments)
      end
    allow_any_instance_of(PaperTrailDiff::PreparedActivitySnapshots)
      .to receive(:custom).and_wrap_original do |original, *arguments, **options|
        reads[:branches] += 1
        original.call(*arguments, **options)
      end
    reads
  end

  def edited_bodies(step)
    step.diff.associations.fetch('comments').changed
        .to_h { |change| [change.record.id, change.attributes.fetch('body').to_h] }
  end

  # A transaction's changes appear at the event after its last. Each of its
  # versions is applied there to the comment it saved, as a version alone in
  # its transaction is, so no snapshot reads every comment again.
  it 'applies each version of a transaction that saved several comments' do
    article = TrackedArticle.create!(title: 'Draft')
    one, two, three = Array.new(3) { |index| article.comments.create!(body: "Comment #{index}") }
    start = article.versions.reorder(:created_at, :id).last
    TrackedComment.transaction do
      one.update!(body: 'One')
      two.update!(body: 'Two')
    end
    three.update!(body: 'Three')
    reads = snapshot_reads

    steps = SpecTimelines.activity_timeline(article, from: start, to: article.reload,
                                                     associations: [:comments])

    expect(reads).to eq(whole: 2, branches: 0)
    expect(steps.reject(&:empty?).last(2).map { |step| edited_bodies(step) }).to eq(
      [{ one.id => { from: 'Comment 0', to: 'One' }, two.id => { from: 'Comment 1', to: 'Two' } },
       { three.id => { from: 'Comment 2', to: 'Three' } }]
    )
  end

  # A comment created, or destroyed, changes who is in the collection. Reading
  # the whole collection again for each such event made a replay's time grow
  # with its events times the comments they left: 3,000 comments created one
  # at a time took 19 s. Each record's sort key is read once per record a
  # step examines, so the count of keys read says how much of the collection
  # each event touched.
  it 'replays comments created one at a time without reading the collection for each' do
    keys_read = lambda do |comments|
      article = TrackedArticle.create!(title: 'Draft')
      start = article.versions.last
      comments.times { |index| article.comments.create!(body: "Comment #{index}") }
      article.comments.first.destroy!
      count = 0
      allow(PaperTrailDiff::Support).to receive(:sortable_identity).and_wrap_original do |key, *id|
        count += 1
        key.call(*id)
      end
      steps = SpecTimelines.activity_timeline(article, from: start, to: article.reload,
                                                       associations: [:comments])
      expect(steps.size).to eq(comments + 2)
      count
    end

    few = keys_read.call(40)
    many = keys_read.call(160)

    # Four times the events may read four times the keys, and a search of a
    # longer collection a few more for each; not sixteen times.
    expect(many).to be < few * 8
  end

  # The same holds when the article is among the records the transaction
  # saved, before its comment or after it, as `touch: true` saves it.
  it 'applies each version of a transaction that saved the article and a comment' do
    article = TrackedArticle.create!(title: 'Draft')
    comment = article.comments.create!(body: 'First')
    start = article.versions.reorder(:created_at, :id).last
    TrackedArticle.transaction do
      comment.update!(body: 'Second')
      article.update!(title: 'Edited')
    end
    TrackedArticle.transaction do
      article.update!(title: 'Final')
      comment.update!(body: 'Third')
    end
    comment.update!(body: 'Fourth')
    reads = snapshot_reads

    steps = SpecTimelines.activity_timeline(article, from: start, to: article.reload,
                                                     associations: [:comments])

    expect(reads).to eq(whole: 2, branches: 0)
    reported = steps.reject(&:empty?).last(4)
    expect(reported.map { |step| step.diff.attributes['title']&.to })
      .to eq(['Edited', 'Final', nil, nil])
    expect(reported.map { |step| step.diff.associations.key?('comments') })
      .to eq([true, false, true, true])
    expect(reported.values_at(0, 2, 3).map { |step| edited_bodies(step).fetch(comment.id) }).to eq(
      [{ from: 'First', to: 'Second' }, { from: 'Second', to: 'Third' },
       { from: 'Third', to: 'Fourth' }]
    )
  end

  # The snapshot at the article's update reads the comments as they stood
  # before its transaction, and so does the one at the comment's event after
  # it, in the same transaction: only the article's own version lies between
  # them, so its snapshot is carried forward, as after an update alone in its
  # transaction. The create has none to carry.
  it "carries the article's snapshot to the next event of its transaction" do
    article = TrackedArticle.create!(title: 'Draft')
    comment = article.comments.create!(body: 'First')
    TrackedArticle.transaction do
      article.update!(title: 'Edited')
      comment.update!(body: 'Edited')
    end
    first = article.versions.reorder(:created_at, :id).first
    carried = []
    allow_any_instance_of(PaperTrailDiff::ActivityRootSnapshotRefresher)
      .to receive(:call).and_wrap_original do |original, *arguments|
        original.call(*arguments).tap { |result| carried << result.first }
      end

    steps = SpecTimelines.activity_timeline(article, from: first, to: article.reload,
                                                     associations: [:comments])

    expect(carried).to eq([false, true])
    edit, comment_edit = steps.last(2)
    expect(edit.diff.attributes.fetch('title').to_h).to eq(from: 'Draft', to: 'Edited')
    expect(comment_edit.diff.associations.fetch('comments').changed
      .map { |change| change.attributes.fetch('body').to_h })
      .to eq([{ from: 'First', to: 'Edited' }])
  end

  # The snapshot at a root version starts from the state that version stored,
  # and the next one from the state stored at the root's next version, which
  # is decoded for it anyway. Comparing the two says which branches to read
  # again, without decoding the version's recorded changes.
  it "carries an article's edits forward without decoding their recorded changes" do
    article = TrackedArticle.create!(title: 'Draft')
    article.comments.create!(body: 'First')
    3.times { |index| article.update!(title: "Edit #{index}") }
    first = article.versions.reorder(:created_at, :id).first
    expect_any_instance_of(PaperTrailDiff::ActivityEventRecordResolver)
      .not_to receive(:deserialized_changeset)
    expect_any_instance_of(PaperTrailDiff::PreparedRecordIndex).not_to receive(:transition)

    steps = SpecTimelines.activity_timeline(article, from: first, to: article.reload,
                                                     associations: [:comments])

    titles = steps.filter_map { |step| step.diff.attributes['title']&.to_h }
    expect(titles).to eq([{ from: 'Draft', to: 'Edit 0' }, { from: 'Edit 0', to: 'Edit 1' },
                          { from: 'Edit 1', to: 'Edit 2' }])
  end
end
