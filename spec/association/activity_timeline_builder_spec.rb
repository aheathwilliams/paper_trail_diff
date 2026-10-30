# frozen_string_literal: true

require_relative '../support/association_database'

# Driven through the public entry points, which build one of these for every
# version-bounded activity timeline and analysis.
RSpec.describe PaperTrailDiff::ActivityTimelineBuilder do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    ActiveRecord::Base.connection.execute('DELETE FROM tracked_articles_tags')
    [TrackedReply, TrackedComment, TrackedArticle, TrackedAuthor, TrackedTag].each(&:delete_all)
  end

  def version_of(record)
    record.versions.reorder(:created_at, :id).last
  end

  def checkpoint(article)
    TrackedArticle.transaction { TrackedArticle.find(article.id).paper_trail.save_with_version }
    version_of(article)
  end

  def timeline(article, **options)
    PaperTrailDiff.activity_timeline(article, associations: [:comments], **options)
  end

  def analysis(article, **options)
    PaperTrailDiff.analyze(article, associations: [:comments], activity: true, **options)
  end

  def kinds(steps)
    steps.map do |step|
      [step.from_boundary.item_type, step.from_boundary.event, step.to_boundary.kind.to_s]
    end
  end

  def bodies(snapshot)
    snapshot.associations.fetch('comments').records.map { |comment| comment.attributes['body'] }
  end

  def comment_bodies(step)
    comments = step.diff.associations['comments']
    return [] unless comments

    comments.changed.map do |change|
      change.attributes.fetch('body').to_h
    end
  end

  # An article with one comment edited twice between two article versions.
  def edited_history
    article = TrackedArticle.create!(title: 'Article')
    comment = article.comments.create!(body: 'one')
    from = checkpoint(article)
    comment.update!(body: 'two')
    comment.update!(body: 'three')
    to = checkpoint(article)
    [article, comment, from, to]
  end

  describe 'between two versions' do
    it 'reports a step for each root and child change, closed on the last version' do
      article, _comment, from, to = edited_history

      steps = timeline(article, from: from, to: to)

      expect(kinds(steps)).to eq([%w[TrackedArticle update version],
                                  %w[TrackedComment update version],
                                  %w[TrackedComment update version]])
      expect(steps.last.to_boundary.version_id).to eq(to.id)
      expect(steps.map { |step| comment_bodies(step) })
        .to eq([[], [{ from: 'one', to: 'two' }], [{ from: 'two', to: 'three' }]])
      expect(steps).to be_frozen
    end

    it 'analyzes the endpoints, the root timeline, and the activity in one pass' do
      article, _comment, from, to = edited_history

      result = analysis(article, from: from, to: to)

      expect(comment_bodies(result)).to eq([{ from: 'one', to: 'three' }])
      expect(result.timeline.length).to eq(1)
      expect(result.activity_timeline.length).to eq(3)
      expect(bodies(result.from_snapshot)).to eq(['one'])
      expect(bodies(result.to_snapshot)).to eq(['three'])
    end

    it 'closes a destroyed root on its removal, in the activity view only' do
      article, comment, from, = edited_history
      comment.destroy!
      article.reload.destroy!
      destroy = version_of(article)

      steps = timeline(article, from: from, to: destroy)
      result = analysis(article, from: from, to: destroy)

      expect(steps.last.to_boundary.kind).to eq(:destroyed)
      expect(steps.last.to_boundary.version_id).to eq(destroy.id)
      expect(steps.last.to_snapshot).to be_nil
      expect(result.activity_timeline.last.to_boundary.kind).to eq(:destroyed)
      expect(result.to_snapshot).not_to be_nil
      expect(result.timeline.last.to_boundary.kind).to eq(:version)
    end

    # As `touch: true` does: the child's version comes first, but the closing
    # version's state is the state before their shared transaction.
    it 'ends before a child change saved in the transaction of its last version' do
      article = TrackedArticle.create!(title: 'Article')
      comment = article.comments.create!(body: 'one')
      from = checkpoint(article)
      TrackedArticle.transaction do
        comment.update!(body: 'two')
        TrackedArticle.find(article.id).paper_trail.save_with_version
      end
      to = version_of(article)
      expect(version_of(comment).transaction_id).to eq(to.transaction_id)

      steps = timeline(article, from: from, to: to, snapshots: true)
      result = analysis(article, from: from, to: to)

      expect(kinds(steps)).to eq([%w[TrackedArticle update version]])
      expect(bodies(steps.last.to_snapshot)).to eq(['one'])
      expect(kinds(result.activity_timeline)).to eq(kinds(steps))
      expect(bodies(result.to_snapshot)).to eq(['one'])
    end

    it 'does not add a removal when the range does not end on a destroy' do
      article, _comment, from, to = edited_history

      expect(timeline(article, from: from, to: to).map { |step| step.to_boundary.kind }.uniq)
        .to eq([:version])
    end

    it 'returns no steps for a range with no versions' do
      article = TrackedArticle.create!(title: 'Article')
      from = checkpoint(article)

      expect(timeline(article, from: from, to: from)).to eq([])
      expect(analysis(article, from: from, to: from).activity_timeline).to eq([])
    end
  end

  describe 'to the current record' do
    it 'closes on the live row, captured when the timeline is built' do
      article, comment, from, = edited_history
      comment.update!(body: 'live')
      before = Time.now.utc

      steps = timeline(article, from: from, to: article, snapshots: true)

      closing = steps.last
      expect(closing.to_boundary.kind).to eq(:current)
      expect(closing.to_boundary.recorded_at).to be >= before
      expect(comment_bodies(closing)).to eq([{ from: 'three', to: 'live' }])
      expect(bodies(closing.to_snapshot)).to eq(['live'])
    end

    it 'analyzes up to the live row' do
      article, comment, from, = edited_history
      comment.update!(body: 'live')

      result = analysis(article, from: from, to: article)

      expect(comment_bodies(result)).to eq([{ from: 'one', to: 'live' }])
      expect(bodies(result.to_snapshot)).to eq(['live'])
      expect(result.activity_timeline.last.to_boundary.kind).to eq(:current)
      expect(comment_bodies(result.activity_timeline.last)).to eq([{ from: 'three', to: 'live' }])
      expect(result.timeline.last.to_boundary.kind).to eq(:current)
    end

    it 'requires a root version to start from' do
      article = TrackedArticle.create!(title: 'Article')

      expect { timeline(article, from: article, to: article) }
        .to raise_error(PaperTrailDiff::InvalidTimelineRangeError,
                        '`from` must be a root PaperTrail version')
    end

    it 'rejects an endpoint of another record' do
      article = TrackedArticle.create!(title: 'Article')
      other = TrackedArticle.create!(title: 'Other')

      expect { timeline(article, from: version_of(article), to: other) }
        .to raise_error(PaperTrailDiff::VersionMismatchError)
      expect { timeline(other, from: version_of(article), to: article) }
        .to raise_error(PaperTrailDiff::VersionMismatchError)
    end

    it 'refuses HABTM activity that runs into live state' do
      article = TrackedArticle.create!(title: 'Article')
      from = checkpoint(article)

      expect do
        PaperTrailDiff.activity_timeline(article, from: from, to: article, associations: [:tags])
      end.to raise_error(PaperTrailDiff::UnsupportedLiveActivityError, /tags/)
    end
  end

  describe 'group: :transaction' do
    it 'merges a save that touched the root and a child into one step' do
      article = TrackedArticle.create!(title: 'Article')
      comment = article.comments.create!(body: 'one')
      from = checkpoint(article)
      TrackedArticle.transaction do
        article.update!(title: 'Retitled')
        comment.update!(body: 'two')
      end
      to = checkpoint(article)

      grouped = timeline(article, from: from, to: to, group: :transaction)
      plain = timeline(article, from: from, to: to)

      expect(plain.length).to be > grouped.length
      expect(grouped.map { |step| step.diff.attributes.keys })
        .to include(include('title'))
      expect(grouped.map(&:from_snapshot)).to all(be_nil)
      expect(timeline(article, from: from, to: to, group: :transaction, snapshots: true)
               .map(&:from_snapshot)).to all(be_a(PaperTrailDiff::RecordSnapshot))
    end

    it 'rejects any other grouping' do
      article = TrackedArticle.create!(title: 'Article')

      expect { timeline(article, from: version_of(article), to: article, group: :save) }
        .to raise_error(PaperTrailDiff::ConfigurationError, 'group: must be :transaction or nil')
    end
  end

  it 'keeps snapshots only when asked' do
    article, _comment, from, to = edited_history

    expect(timeline(article, from: from, to: to).map(&:to_snapshot)).to all(be_nil)
    expect(timeline(article, from: from, to: to, snapshots: true).map(&:to_snapshot))
      .to all(be_a(PaperTrailDiff::RecordSnapshot))
  end

  it 'hands a window to the time-based builder' do
    article = TrackedArticle.create!(title: 'Article')
    comment = article.comments.create!(body: 'one')
    start = Time.now.utc
    comment.update!(body: 'two')

    steps = timeline(article, within: start..Time.now.utc)
    result = analysis(article, within: start..Time.now.utc)

    expect(steps.flat_map { |step| comment_bodies(step) }).to eq([{ from: 'one', to: 'two' }])
    expect(comment_bodies(result)).to eq([{ from: 'one', to: 'two' }])
  end

  describe 'built directly' do
    let(:adapter) do
      PaperTrailDiff::PaperTrailAdapter.new(associations: [:comments],
                                            ignore: PaperTrailDiff::DEFAULT_IGNORED_ATTRIBUTES)
    end
    let(:provider) { adapter.instance_variable_get(:@activity_snapshotter) }

    def builder(record, from:, to:, snapshotter: provider, live: nil)
      range = PaperTrailDiff::TimelineRange.new(record, from: from, to: to, within: nil,
                                                        live_endpoint: live)
      tree = PaperTrailDiff::AssociationTree.build([:comments])
      described_class.new(record, range: range, tree: tree, snapshotter: snapshotter,
                                  snapshots: false, group: nil)
    end

    def collector_calls
      calls = []
      collector = PaperTrailDiff::ActivityVersionCollector
      allow(collector).to receive(:new).and_wrap_original do |original, *args, **options|
        calls << options
        original.call(*args, **options)
      end
      calls
    end

    it 'prepares history over the root versions and reads events from the first to the last' do
      article, _comment, from, to = edited_history
      allow(provider).to receive(:prepare).and_call_original
      calls = collector_calls

      builder(article, from: from, to: to).build
      builder(article, from: from, to: to).analyze

      versions = [from, to]
      expect(provider).to have_received(:prepare).twice
      expect(provider).to have_received(:prepare).with(article, versions).twice
      expect(calls.map { |call| call.slice(:root_versions, :range_start, :range_end) })
        .to eq([{ root_versions: versions, range_start: from, range_end: to }] * 2)
      expect(calls.map { |call| call[:prepared] }).to all(be_a(PaperTrailDiff::PreparedActivityIndex))
      expect(calls.last[:prepared]).to equal(provider.activity_index)
    end

    it 'prepares history up to the moment it captures the live row' do
      article, _comment, from, to = edited_history
      allow(provider).to receive(:prepare).and_call_original
      calls = collector_calls
      before = Time.now.utc

      steps = builder(article, from: from, to: article, live: article).build

      captured = steps.last.to_boundary.recorded_at
      expect(captured).to be >= before
      expect(captured).to be_utc
      expect(provider).to have_received(:prepare).with(article, [from, to], end_at: captured)
      expect(calls.first.slice(:range_start, :range_end))
        .to eq(range_start: from, range_end: captured)
      expect(steps.last.from_boundary.version_id).to eq(to.id)
    end

    it 'reads the same activity from a snapshotter that cannot prepare' do
      article, comment, from, to = edited_history
      comment.update!(body: 'live')
      plain = adapter.method(:snapshot_at)
      calls = collector_calls

      expected = [builder(article, from: from, to: to).build,
                  builder(article, from: from, to: article, live: article).build]
      found = [builder(article, from: from, to: to, snapshotter: plain).build,
               builder(article, from: from, to: article, live: article, snapshotter: plain).build]

      strip = lambda { |steps|
        steps.map do |step|
          step.to_h.merge(to: step.to_h[:to].except(:recorded_at))
        end
      }
      expect(found.map(&strip)).to eq(expected.map(&strip))
      expect(calls.last(2).map { |call| call[:prepared] }).to eq([nil, nil])
    end

    it 'returns nothing for a record with no versions' do
      article = PaperTrail.request(enabled: false) { TrackedArticle.create!(title: 'Unversioned') }

      steps = builder(article, from: :first, to: article, live: article).build
      result = builder(article, from: :first, to: article, live: article).analyze

      expect(steps).to eq([])
      expect(steps).to be_frozen
      expect(result.activity_timeline).to eq([])
      expect(result.timeline).to eq([])
      expect(result.diff).to be_empty
    end

    it 'rejects a to that is neither a version nor a record' do
      article, _comment, from, = edited_history

      expect { builder(article, from: from, to: 'nope').build }
        .to raise_error(PaperTrailDiff::InvalidEndpointError,
                        'expected a PaperTrail version or persisted record endpoint')
    end
  end

  it 'names another record version as a from that does not match' do
    article = TrackedArticle.create!(title: 'Article')
    other = TrackedArticle.create!(title: 'Other')

    expect { timeline(article, from: version_of(other), to: article) }
      .to raise_error(PaperTrailDiff::VersionMismatchError,
                      'endpoints must belong to the same PaperTrail item')
  end

  it 'closes the root timeline on the captured live row' do
    article, _comment, from, = edited_history
    TrackedArticle.where(id: article.id).update_all(title: 'Unrecorded')

    result = analysis(article, from: from, to: article.reload)

    expect(bodies(result.from_snapshot)).to eq(['one'])
    expect(result.timeline.last.to_boundary.recorded_at)
      .to eq(result.activity_timeline.last.to_boundary.recorded_at)
    expect(result.timeline.last.diff.attributes.fetch('title').to_h)
      .to eq(from: 'Article', to: 'Unrecorded')
  end

  it 'groups and keeps snapshots in a window too' do
    article = TrackedArticle.create!(title: 'Article')
    comment = article.comments.create!(body: 'one')
    start = Time.now.utc
    TrackedArticle.transaction do
      article.update!(title: 'Retitled')
      comment.update!(body: 'two')
    end
    window = start..Time.now.utc

    grouped = timeline(article, within: window, group: :transaction)
    kept = timeline(article, within: window, snapshots: true)

    expect(grouped.length).to be < timeline(article, within: window).length
    expect(kept.map(&:to_snapshot)).to all(be_a(PaperTrailDiff::RecordSnapshot))
  end

  describe 'with a version filter' do
    it 'closes on the successor of the last version it keeps, not on the live row' do
      article = TrackedArticle.create!(title: 'Kept')
      comment = article.comments.create!(body: 'one')
      kept = version_of(article)
      article.update!(title: 'Later')
      comment.update!(body: 'after the successor')
      scope = ->(versions) { versions.where(id: kept.id) }

      result = analysis(article, from: kept, to: article, version_scope: scope)

      expect(result.to_snapshot.attributes.fetch('title')).to eq('Kept')
      expect(result.activity_timeline.map { |step| step.to_boundary.kind }.uniq).to eq([:version])
      expect(result.activity_timeline.flat_map { |step| comment_bodies(step) }).to eq([])
    end

    it 'returns nothing when it keeps no version' do
      article, _comment, from, to = edited_history
      scope = :none.to_proc

      expect(timeline(article, from: from, to: to, version_scope: scope)).to eq([])
      expect(timeline(article, from: from, to: article, version_scope: scope)).to eq([])
      expect(analysis(article, from: from, to: to,
                               version_scope: scope).activity_timeline).to eq([])
      result = analysis(article, from: from, to: article, version_scope: scope)
      expect([result.activity_timeline, result.timeline]).to eq([[], []])
      expect(result.diff).to be_empty
    end
  end

  it 'reads child changes after the last root version up to the live row' do
    article = TrackedArticle.create!(title: 'Article')
    from = version_of(article)
    comment = article.comments.create!(body: 'one')
    comment.update!(body: 'two')

    steps = timeline(article, from: from, to: article)

    expect(steps.map { |step| comment_bodies(step) }.reject(&:empty?))
      .to eq([[{ from: 'one', to: 'two' }]])
    added = steps.flat_map { |step| step.diff.associations['comments']&.added || [] }
    expect(added.map(&:id)).to eq([comment.id])
  end

  describe 'recorded_changes: true' do
    def recorded(boundary)
      boundary.recorded_changes&.transform_values(&:to_h)
    end

    def sources(step)
      step.sources.map { |source| [source.item_type, recorded(source)] }
    end

    it 'gives every boundary the changes its own version recorded' do
      article, _comment, from, to = edited_history

      steps = timeline(article, from: from, to: to, recorded_changes: true)

      expect(steps.map { |step| recorded(step.from_boundary) })
        .to eq([{}, { 'body' => { from: 'one', to: 'two' } },
                { 'body' => { from: 'two', to: 'three' } }])
      expect(recorded(steps.last.to_boundary)).to eq({})
      expect(steps.map { |step| sources(step) })
        .to eq(steps.map { |step| [[step.from_boundary.item_type, recorded(step.from_boundary)]] })
    end

    it 'reads them in an analysis too' do
      article, _comment, from, to = edited_history

      steps = analysis(article, from: from, to: to, recorded_changes: true).activity_timeline

      expect(recorded(steps.last.source_boundary)).to eq('body' => { from: 'two', to: 'three' })
    end

    it 'does not read them unless asked' do
      article, _comment, from, to = edited_history

      steps = timeline(article, from: from, to: to)

      expect(steps.map { |step| step.from_boundary.recorded_changes? }).to all(be(false))
    end

    it 'reads the destroy that closes a deleted root, at both of its boundaries' do
      article, comment, from, = edited_history
      comment.destroy!
      article.reload.destroy!
      destroy = version_of(article)

      closing = timeline(article, from: from, to: destroy, recorded_changes: true).last

      expect(closing.to_boundary.kind).to eq(:destroyed)
      expect(recorded(closing.to_boundary)).to include('title' => { from: 'Article', to: nil })
      expect(recorded(closing.from_boundary)).to eq(recorded(closing.to_boundary))
    end

    it 'gives the live row no recorded changes, since it has no version' do
      article, comment, from, = edited_history
      comment.update!(body: 'live')

      [timeline(article, from: from, to: article, recorded_changes: true),
       timeline(article, within: (Time.now.utc - 60)..Time.now.utc, close_on: :current,
                         recorded_changes: true)].each do |steps|
        closing = steps.last
        expect(closing.to_boundary.kind).to eq(:current)
        expect(closing.to_boundary.recorded_changes?).to be(true)
        expect(closing.to_boundary.recorded_changes).to be_nil
        expect(recorded(closing.from_boundary)).to eq('body' => { from: 'three', to: 'live' })
      end
    end

    it 'reads them in a window' do
      article = TrackedArticle.create!(title: 'Article')
      comment = article.comments.create!(body: 'one')
      start = Time.now.utc
      comment.update!(body: 'two')

      steps = timeline(article, within: start..Time.now.utc, recorded_changes: true)

      expect(steps.map { |step| recorded(step.source_boundary) })
        .to eq([{ 'body' => { from: 'one', to: 'two' } }])
    end

    it 'reads the destroy that closes a window' do
      article = TrackedArticle.create!(title: 'Article')
      start = Time.now.utc
      article.destroy!

      closing = timeline(article, within: start..Time.now.utc, recorded_changes: true).last

      expect(closing.to_boundary.kind).to eq(:destroyed)
      expect(recorded(closing.to_boundary)).to include('title' => { from: 'Article', to: nil })
      expect(recorded(closing.from_boundary)).to eq(recorded(closing.to_boundary))
    end

    it 'names every version in a transaction group, each with what it recorded' do
      article = TrackedArticle.create!(title: 'Article')
      comment = article.comments.create!(body: 'one')
      from = checkpoint(article)
      TrackedArticle.transaction do
        article.update!(title: 'Retitled')
        comment.update!(body: 'two')
      end
      to = checkpoint(article)

      [timeline(article, from: from, to: to, group: :transaction, recorded_changes: true),
       timeline(article, within: from.created_at..to.created_at, group: :transaction,
                         recorded_changes: true)].each do |steps|
        group = steps.find { |step| step.sources.length > 1 }
        expect(sources(group))
          .to eq([['TrackedArticle', { 'title' => { from: 'Article', to: 'Retitled' } }],
                  ['TrackedComment', { 'body' => { from: 'one', to: 'two' } }]])
      end
    end

    it 'leaves out the attributes ignored everywhere, but not those of one path' do
      article, _comment, from, to = edited_history

      everywhere = timeline(article, from: from, to: to, recorded_changes: true,
                                     ignore: %w[body updated_at])
      one_path = timeline(article, from: from, to: to, recorded_changes: true,
                                   ignore: { paths: { 'comments' => ['body'] } })

      expect(everywhere.map { |step| recorded(step.from_boundary) }).to eq([{}, {}, {}])
      expect(recorded(one_path.last.from_boundary).keys).to eq(%w[body updated_at])
    end

    it 'requires activity' do
      article = TrackedArticle.create!(title: 'Article')

      expect { PaperTrailDiff.analyze(article, recorded_changes: true) }
        .to raise_error(PaperTrailDiff::ConfigurationError,
                        'recorded_changes: requires activity: true')
      expect { PaperTrailDiff.analyze_many([article], recorded_changes: true) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /recorded_changes:/)
      expect { PaperTrailDiff.analyze_scope(TrackedArticle, limit: 1, recorded_changes: true) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /recorded_changes:/)
    end

    it 'reads them in single, batch, scope, deleted, and report calls alike' do
      article = TrackedArticle.create!(title: 'Before')
      gone = TrackedArticle.create!(title: 'Gone')
      start = Time.now.utc
      article.update!(title: 'After')
      gone.destroy!
      options = { within: start..(Time.now.utc + 60), close_on: :current, activity: true,
                  recorded_changes: true }
      expected = [{ 'title' => { from: 'Before', to: 'After' } }]
      titles = lambda do |result|
        result.activity_timeline.map { |step| recorded(step.source_boundary) }
      end

      scope = PaperTrailDiff.analyze_scope(TrackedArticle, limit: 2, include_deleted: true,
                                                           **options)
      report = PaperTrailDiff.report(TrackedArticle, since: start, limit: 2, include_deleted: true,
                                                     recorded_changes: true)

      expect(titles.call(PaperTrailDiff.analyze(article, **options))).to eq(expected)
      expect(titles.call(PaperTrailDiff.analyze_many([article], **options).values.fetch(0)))
        .to eq(expected)
      [scope, report].each do |result|
        expect(titles.call(result.analyses.values.fetch(0))).to eq(expected)
        expect(titles.call(result.deleted.values.fetch(0)).last)
          .to include('title' => { from: 'Gone', to: nil })
      end
    end
  end
end
