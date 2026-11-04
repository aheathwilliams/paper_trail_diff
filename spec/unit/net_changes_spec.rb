# frozen_string_literal: true

require 'paper_trail_diff'

# Steps are built by hand, so each row names its step's source. The specs in
# spec/association/net_changes_spec.rb read real histories, whose rows name
# their own records' versions and split off what no version recorded.
RSpec.describe PaperTrailDiff::NetChanges,
               mutant_expression: %w[PaperTrailDiff::NetChanges PaperTrailDiff::NetChange] do
  def record(type, id, attributes, **associations)
    PaperTrailDiff::RecordSnapshot.new(type: type, id: id, attributes: attributes,
                                       associations: associations)
  end

  def many(*records)
    PaperTrailDiff::AssociationSnapshot.new(kind: :has_many, records: records)
  end

  def article(title, body = 'text', **associations)
    record('Article', 1, { 'title' => title, 'body' => body }, **associations)
  end

  def comment(id, body, **associations)
    record('Comment', id, { 'body' => body }, **associations)
  end

  def version(id, author)
    PaperTrailDiff::ActivityBoundary.new(
      kind: :version, version_id: id, item_type: 'Article', item_id: 1,
      recorded_at: Time.utc(2026) + id, event: 'update', whodunnit: author
    )
  end

  # A step for each move from one state to the next, made by the next source:
  # a version by the author named, or the boundary given.
  def history(states, sources)
    closing = version(99, nil)
    states.each_cons(2).zip(sources).each_with_index.map do |((from, to), source), index|
      source = version(index + 1, source) unless source.is_a?(PaperTrailDiff::ActivityBoundary)
      PaperTrailDiff::ActivityStep.between(from_boundary: source, to_boundary: closing,
                                           from_snapshot: from, to_snapshot: to, retain: true)
    end
  end

  def net(steps, &keep)
    described_class.call(steps, keep)
  end

  # The changes people made: those of a version with an author.
  def authored(steps)
    net(steps) { |row| row.source.whodunnit }
  end

  # Each change as its record's id, whether it was added or removed, and the
  # fields that differ.
  def table(changes)
    changes.map do |change|
      [change.record&.id, change.added?, change.removed?,
       change.diff.attributes.transform_values { |value| [value.from, value.to] }]
    end
  end

  describe 'a record changed in place' do
    let(:steps) do
      states = [article('A'), article('B'), article('Z'), article('Z', 'more')]
      history(states, ['alice', nil, 'bob'])
    end

    it 'makes only the kept changes, to its state before the first of them' do
      change, = authored(steps)

      expect(change.before.attributes).to eq('title' => 'A', 'body' => 'text')
      expect(change.after.attributes).to eq('title' => 'B', 'body' => 'more')
      expect(table([change])).to eq([[nil, false, false,
                                      { 'body' => %w[text more], 'title' => %w[A B] }]])
      expect(change.sources.map(&:version_id)).to eq([1, 3])
    end

    it 'keeps every change without a block' do
      expect(table(net(steps))).to eq([[nil, false, false,
                                        { 'body' => %w[text more], 'title' => %w[A Z] }]])
    end

    it 'starts where the first kept change found it, after the dropped changes before it' do
      change, = net(steps) { |row| row.source.whodunnit == 'bob' }

      expect(change.before.attributes).to eq('title' => 'Z', 'body' => 'text')
      expect(change.after.attributes).to eq('title' => 'Z', 'body' => 'more')
    end

    it 'leaves the record out when its kept changes cancel and nothing else changed' do
      expect(net(history([article('A'), article('B'), article('A')], %w[alice bob]))).to eq([])
    end
  end

  describe 'records that appear and disappear' do
    # Comment 8 is there from the start. Alice adds 7, which the system edits
    # without an author; then Bob removes 8.
    let(:steps) do
      eight = comment(8, 'old')
      seven = record('Comment', 7, { 'body' => 'hi', 'stamp' => 5 })
      drifted = record('Comment', 7, { 'body' => 'drift', 'stamp' => 5 })
      history([article('A', comments: many(eight)), article('A', comments: many(seven, eight)),
               article('A', comments: many(drifted, eight)), article('A', comments: many(drifted))],
              ['alice', nil, 'bob'])
    end

    it 'adds a record with the fields it appeared with, and leaves a removed one nothing after' do
      root, added, removed = authored(steps)

      expect(table([root, added, removed]))
        .to eq([[nil, false, false, {}], [7, true, false, {}], [8, false, true, {}]])
      expect(added.after.attributes).to eq('body' => 'hi', 'stamp' => 5)
      expect(added.diff.record_presence_change.to).to eq(added.after)
      expect(removed.before.attributes).to eq('body' => 'old')
      expect(removed.to_h.slice(:association_path, :association_kind, :record, :after))
        .to eq(association_path: ['comments'], association_kind: :has_many,
               record: { type: 'Comment', id: 8 }, after: nil)
      expect(added.to_h[:before]).to be_nil
      expect([added, removed]).not_to include(be_root)
    end

    it 'gives a field of a record that appears the value it has there when no kept row sets it' do
      _root, added = net(steps) { |row| row.source.whodunnit && row.attribute != 'stamp' }

      expect(added.after.attributes).to eq('body' => 'hi', 'stamp' => 5)
    end

    it 'moves a record in or out only through its own row' do
      expect(net(steps) { |row| row.attribute == 'body' && row.source.whodunnit }).to eq([])
    end

    it 'leaves out a record that appears and goes again among the kept changes' do
      states = [article('A', comments: many), article('A', comments: many(comment(7, 'hi'))),
                article('A', comments: many)]

      expect(net(history(states, %w[alice bob]))).to eq([])
    end
  end

  describe 'the root' do
    it 'comes first, then each record in the order of its first kept change' do
      states = [article('A', comments: many(comment(7, 'a'), comment(8, 'b'))),
                article('A', comments: many(comment(7, 'a'), comment(8, 'c'))),
                article('A', comments: many(comment(7, 'd'), comment(8, 'c'))),
                article('B', comments: many(comment(7, 'd'), comment(8, 'c')))]

      changes = net(history(states, %w[alice alice alice]))

      expect(changes.map { |change| change.record&.id }).to eq([nil, 8, 7])
      expect(changes).to be_frozen
      expect(changes.map { |change| change.before.associations }).to all(eq({}))
      expect(changes.map { |change| change.diff.associations }).to all(eq({}))
    end

    it 'is listed without a kept change of its own, as the first kept change found it' do
      states = [article('A', comments: many(comment(7, 'a'))),
                article('B', comments: many(comment(7, 'a'))),
                article('B', comments: many(comment(7, 'b')))]
      root, edited = authored(history(states, [nil, 'alice']))

      expect(root.before.attributes).to eq('title' => 'B', 'body' => 'text')
      expect(root.before.associations).to eq({})
      expect(root.after).to equal(root.before)
      expect(root.diff).to be_empty
      expect(root.sources).to eq([])
      expect(table([edited])).to eq([[7, false, false, { 'body' => %w[a b] }]])
    end

    it "is read where its first kept change's step began, when a dropped row there changed it" do
      states = [article('A', comments: many(comment(7, 'a'))),
                article('B', comments: many(comment(7, 'b')))]
      root, = net(history(states, ['alice']), &:record)

      expect(root.before.attributes).to eq('title' => 'A', 'body' => 'text')
    end

    it 'is read where it appeared when a dropped change created it' do
      created = article('A', comments: many(comment(7, 'a')))
      root, added = net(history([nil, created], ['alice']), &:record)

      expect(root.before.attributes).to eq('title' => 'A', 'body' => 'text')
      expect(table([root, added])).to eq([[nil, false, false, {}], [7, true, false, {}]])
    end
  end

  describe 'records along a path' do
    # Comment 1 holds no replies that were read. Reply 5 moves from comment 3
    # to comment 2, which the diff walks first, losing its note, while comment
    # 1 is edited.
    it 'follows a record that moves between the records holding it' do
      reply = record('Reply', 5, { 'body' => 'r', 'note' => 'n' })
      moved = record('Reply', 5, { 'body' => 'moved', 'note' => nil })
      before = article('A', comments: many(comment(1, 'one'), comment(2, 'two', replies: many),
                                           comment(3, 'three', replies: many(reply))))
      after = article('A', comments: many(comment(1, 'uno'),
                                          comment(2, 'two', replies: many(moved)),
                                          comment(3, 'three', replies: many)))
      changes = net(history([before, after], ['alice']))

      expect(changes.map(&:association_path)).to eq([[], ['comments'], %w[comments replies]])
      expect(table(changes)).to eq([[nil, false, false, {}],
                                    [1, false, false, { 'body' => %w[one uno] }],
                                    [5, false, false,
                                     { 'body' => %w[r moved], 'note' => ['n', nil] }]])
    end

    it 'removes a record with the records holding it' do
      before = article('A', comments: many(comment(2, 'two', replies: many(comment(5, 'r')))))
      changes = net(history([before, article('A')], ['alice']))

      expect(table(changes))
        .to eq([[nil, false, false, {}], [2, false, true, {}], [5, false, true, {}]])
    end

    it 'knows a record by its path and type as well as its id' do
      one = ->(item) { PaperTrailDiff::AssociationSnapshot.new(kind: :has_one, records: [item]) }
      state = lambda do |text|
        article('A', comments: many(comment(7, text)), pinned: one.call(comment(7, text)),
                     files: many(record('Image', 3, { 'body' => text }),
                                 record('Sheet', 3, { 'body' => text })))
      end
      changes = net(history([state.call('a'), state.call('b')], ['alice']))

      expect(changes.drop(1).map { |change| [change.association_path, change.record.type] })
        .to eq([[['comments'], 'Comment'], [['files'], 'Image'], [['files'], 'Sheet'],
                [['pinned'], 'Comment']])
      expect(changes.drop(1).map { |change| change.diff.attributes.keys }).to all(eq(['body']))
    end
  end

  it 'needs each step that changed something to keep its snapshots' do
    steps = history([article('A'), article('B')], ['alice'])
    bare = steps.map do |step|
      PaperTrailDiff::ActivityStep.new(from_boundary: step.from_boundary,
                                       to_boundary: step.to_boundary, diff: step.diff)
    end
    empty = PaperTrailDiff::ActivityStep.new(from_boundary: version(9, 'alice'),
                                             to_boundary: version(10, nil),
                                             diff: PaperTrailDiff::Diff.new)

    [bare, steps + bare].each do |read|
      expect { net(read) { false } }
        .to raise_error(PaperTrailDiff::ConfigurationError, 'net_changes requires snapshots: true')
    end
    expect(table(net([empty] + steps))).to eq([[nil, false, false, { 'title' => %w[A B] }]])
    expect(net([empty])).to eq([]).and be_frozen
  end

  it 'lists the events of the kept changes in order, each once' do
    unversioned = -> { PaperTrailDiff::ActivityBoundary.unversioned(item_type: 'Article', item_id: 1) }
    states = [article('A'), article('B', 'more'), article('C', 'more'), article('D', 'more')]
    change, = net(history(states, ['alice', unversioned.call, unversioned.call]))

    expect(change.sources.map { |source| [source.kind, source.version_id] })
      .to eq([[:version, 1], [:unversioned, nil]])
    expect(change.sources).to be_frozen
  end

  it 'reads as a hash' do
    change, = net(history([article('A'), article('B')], ['alice']))

    expect(change.to_h).to eq(
      association_path: [], association_kind: nil, record: nil,
      before: { type: 'Article', id: 1, attributes: { 'body' => 'text', 'title' => 'A' } },
      after: { type: 'Article', id: 1, attributes: { 'body' => 'text', 'title' => 'B' } },
      diff: { record_presence_change: nil, attributes: { 'title' => { from: 'A', to: 'B' } },
              associations: {} },
      sources: [version(1, 'alice').to_h(metadata: true)]
    )
    expect(change).to be_root
    expect(change).to be_frozen
  end
end
