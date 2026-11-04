# frozen_string_literal: true

require 'paper_trail_diff'

# Rows and boundaries are built by hand; ChangeRows and the history builders
# that make them are checked in spec/association/change_row_sources_spec.rb.
RSpec.describe PaperTrailDiff::ChangeAttribution do
  # Stand-ins for versioned models: the article's subclass shares its rows,
  # and the comment records every column but `rank`.
  def model(options = {})
    paper_trail = { ignore: [], skip: [], only: [] }.merge(options)
    Class.new do
      define_singleton_method(:base_class) { self }
      define_singleton_method(:paper_trail_options) { paper_trail }
    end
  end

  before do
    article = stub_const('AttributedArticle', model)
    note = Class.new(article) { define_singleton_method(:base_class) { article } }
    stub_const('AttributedNote', note)
    stub_const('AttributedComment', model(ignore: ['rank']))
  end

  let(:root) { PaperTrailDiff::RecordReference.new(type: 'AttributedArticle', id: 1) }
  let(:comment) { PaperTrailDiff::RecordReference.new(type: 'AttributedComment', id: 7) }
  # The step's own source, which a row nothing else accounts for keeps.
  let(:step_source) { version('AttributedArticle', 1, 90) }

  # `changes` maps names to [from, to]; :not_read leaves them unread, and nil
  # is a version that recorded nothing.
  def version(type, id, version_id, event: 'update', changes: :not_read)
    recorded = {}
    unless changes == :not_read
      recorded[:recorded_changes] = changes&.transform_values do |(from, to)|
        PaperTrailDiff::ValueChange.new(from: from, to: to)
      end
    end
    PaperTrailDiff::ActivityBoundary.new(
      kind: :version, version_id: version_id, item_type: type, item_id: id,
      recorded_at: Time.utc(2026), event: event, whodunnit: 'alice', transaction_id: 4, **recorded
    )
  end

  def row(change, attribute, from, to, record: nil)
    PaperTrailDiff::ChangeRow.new(
      change: change, association_path: record ? ['comments'] : [],
      association_kind: (:has_many if record), record: record, attribute: attribute,
      from: from, to: to, source: step_source
    )
  end

  def attribution(sources, preceding: [], complete: true)
    transaction = described_class::Transaction.new
    preceding.each { |boundary| transaction.add(boundary) }
    described_class.new(root: root, sources: sources, complete: complete, transaction: transaction)
  end

  # Each row as its change, field, values, and the version it is credited to.
  def credited(attribution, row)
    attribution.call(row).map do |result|
      source = result.source.unversioned? ? :unversioned : result.source.version_id
      [result.change, result.attribute, result.from, result.to, source]
    end
  end

  describe 'crediting' do
    it 'keeps a row about a record without a version among its sources' do
      edit = row(:changed, 'body', 'a', 'b', record: comment)

      expect(attribution([version('AttributedArticle', 1, 1)]).call(edit)).to eq([edit])
    end

    it "credits a field to the last of the record's versions that recorded it" do
      sources = [version('AttributedArticle', 1, 1, changes: { 'title' => %w[A B] }),
                 version('AttributedComment', 7, 2, changes: { 'body' => %w[a b] }),
                 version('AttributedArticle', 1, 3, changes: { 'title' => %w[B C] }),
                 version('AttributedArticle', 1, 4, changes: { 'rank' => [1, 2] })]

      expect(credited(attribution(sources), row(:changed, 'title', 'A', 'C')))
        .to eq([[:changed, 'title', 'A', 'C', 3]])
      expect(credited(attribution(sources), row(:changed, 'body', 'a', 'b', record: comment)))
        .to eq([[:changed, 'body', 'a', 'b', 2]])
    end

    it "tells records apart by class and id, and keeps each row's own fields" do
      article = PaperTrailDiff::RecordReference.new(type: 'AttributedArticle', id: 7)
      sibling = PaperTrailDiff::RecordReference.new(type: 'AttributedComment', id: 8)
      read = attribution([version('AttributedArticle', 7, 1, changes: { 'body' => %w[a b] }),
                          version('AttributedComment', 8, 2, changes: { 'body' => %w[a b] }),
                          version('AttributedComment', 7, 3, changes: { 'body' => %w[a c] })])
      edit = row(:changed, 'body', 'a', 'b', record: comment)

      expect(credited(read, edit))
        .to eq([[:changed, 'body', 'a', 'c', 3], [:changed, 'body', 'c', 'b', :unversioned]])
      expect(credited(read, row(:changed, 'body', 'a', 'b', record: article)))
        .to eq([[:changed, 'body', 'a', 'b', 1]])
      expect(credited(read, row(:changed, 'body', 'a', 'b', record: sibling)))
        .to eq([[:changed, 'body', 'a', 'b', 2]])
      read.call(edit).each do |split|
        expect([split.association_path, split.association_kind, split.record, split.attribute])
          .to eq([['comments'], :has_many, comment, 'body'])
      end
    end

    it "reads the versions its transaction saved before the step's own" do
      earlier = version('AttributedComment', 7, 2, changes: { 'body' => %w[a b] })
      later = version('AttributedArticle', 1, 3, changes: { 'title' => %w[A B] })
      read = attribution([later], preceding: [earlier])

      expect(credited(read, row(:changed, 'body', 'a', 'b', record: comment)))
        .to eq([[:changed, 'body', 'a', 'b', 2]])
      expect(credited(read.with_sources([later]), row(:changed, 'body', 'a', 'b', record: comment)))
        .to eq([[:changed, 'body', 'a', 'b', 2]])
    end

    it 'keeps its root, completeness and earlier boundaries with a group sources' do
      earlier = version('AttributedComment', 7, 2, changes: { 'body' => %w[a b] })
      later = version('AttributedArticle', 1, 3, changes: { 'title' => %w[A B] })
      group = attribution([later], preceding: [earlier]).with_sources([later])
      partial = attribution([later], complete: false).with_sources([later])

      expect(credited(group,
                      row(:changed, 'title', 'A', 'B'))).to eq([[:changed, 'title', 'A', 'B', 3]])
      expect(credited(group, row(:changed, 'summary', nil, 'x')))
        .to eq([[:changed, 'summary', nil, 'x', :unversioned]])
      expect(credited(partial, row(:changed, 'summary', nil, 'x')))
        .to eq([[:changed, 'summary', nil, 'x', 3]])
      expect(credited(group, row(:changed, 'body', 'a', 'b', record: comment)))
        .to eq([[:changed, 'body', 'a', 'b', 2]])
    end

    # The history adds each boundary to its transaction as it reads it, so a
    # group's own sources are in the transaction too, after those before it.
    it "reads a group's own sources once, after its transaction's earlier boundaries" do
      transaction = described_class::Transaction.new
      earlier = version('AttributedArticle', 1, 1, changes: { 'title' => %w[A B] })
      first = version('AttributedArticle', 1, 2, changes: { 'title' => %w[B C] })
      second = version('AttributedArticle', 1, 3, changes: { 'title' => %w[C D] })
      transaction.add(earlier)
      opening = described_class.new(root: root, sources: [first], complete: true,
                                    transaction: transaction)
      [first, second].each { |boundary| transaction.add(boundary) }

      expect(credited(opening.with_sources([first, second]), row(:changed, 'title', 'B', 'D')))
        .to eq([[:changed, 'title', 'B', 'D', 3]])

      created = described_class::Transaction.new
      create = version('AttributedComment', 7, 4, event: 'create',
                                                  changes: { 'body' => [nil, 'a'] })
      edit = version('AttributedComment', 7, 5, changes: { 'body' => %w[a b] })
      opened = described_class.new(root: root, sources: [create], complete: true,
                                   transaction: created)
      [create, edit].each { |boundary| created.add(boundary) }

      expect(credited(opened.with_sources([create, edit]),
                      row(:added, 'body', nil, 'b', record: comment)))
        .to eq([[:added, 'body', nil, 'b', 5]])
    end

    it 'keeps its own copy of the sources, frozen' do
      sources = [version('AttributedArticle', 1, 1, changes: { 'title' => %w[A B] })]
      read = attribution(sources)
      sources.clear

      expect(read).to be_frozen
      expect(credited(read,
                      row(:changed, 'title', 'A', 'B'))).to eq([[:changed, 'title', 'A', 'B', 1]])
    end

    # A step reads the boundaries its transaction kept before its own, not
    # those added after it, which belong to later steps.
    it "reads a transaction's boundaries before its own sources, once for each record" do
      transaction = described_class::Transaction.new
      first = version('AttributedComment', 7, 1, changes: { 'body' => %w[a b] })
      later = version('AttributedComment', 7, 2, changes: { 'body' => %w[b c] })
      transaction.add(first)
      read = described_class.new(root: root, sources: [step_source], complete: true,
                                 transaction: transaction)
      transaction.add(later)
      allow(transaction).to receive(:of).and_call_original
      named = ->(boundary) { [boundary.item_type, boundary.item_id.to_s] }

      2.times do
        expect(credited(read, row(:changed, 'body', 'a', 'b', record: comment)))
          .to eq([[:changed, 'body', 'a', 'b', 1]])
      end
      expect(transaction).to have_received(:of).once
      expect(transaction.of(%w[AttributedComment 7], 2, &named)).to eq([first, later])
      expect(transaction.of(%w[AttributedComment 8], 2, &named)).to eq([])
      last = version('AttributedComment', 7, 3)
      transaction.add(last)
      expect(transaction.of(%w[AttributedComment 7], 3, &named)).to eq([first, later, last])
    end

    it "credits a field to the record's last version when what they recorded is unknown" do
      unread = [version('AttributedArticle', 1, 1), version('AttributedArticle', 1, 2)]
      silent = [version('AttributedArticle', 1, 1, changes: { 'title' => %w[A B] }),
                version('AttributedArticle', 1, 2, changes: nil)]
      partly = [version('AttributedArticle', 1, 1, changes: { 'title' => %w[A B] }),
                version('AttributedArticle', 1, 2)]

      [unread, silent, partly].each do |sources|
        expect(credited(attribution(sources), row(:changed, 'title', 'A', 'Z')))
          .to eq([[:changed, 'title', 'A', 'Z', 2]])
      end
    end

    it 'finds a subclass by its base class, and a type it cannot load by its name' do
      note = PaperTrailDiff::RecordReference.new(type: 'AttributedNote', id: 1)
      missing = PaperTrailDiff::RecordReference.new(type: 'Missing::Model', id: '5')
      sources = [version('AttributedArticle', 1, 1, changes: { 'title' => %w[A B] }),
                 version('Missing::Model', 5, 2, changes: { 'name' => %w[x y] })]

      expect(credited(attribution(sources), row(:changed, 'title', 'A', 'B', record: note)))
        .to eq([[:changed, 'title', 'A', 'B', 1]])
      expect(credited(attribution(sources), row(:changed, 'name', 'x', 'y', record: missing)))
        .to eq([[:changed, 'name', 'x', 'y', 2]])
      # Without the class, nothing says the column is recorded.
      expect(credited(attribution(sources), row(:changed, 'size', 1, 2, record: missing)))
        .to eq([[:changed, 'size', 1, 2, 2]])
      split = attribution(sources).call(row(:changed, 'name', 'x', 'z', record: missing)).last
      expect([split.source.item_type, split.source.item_id]).to eq(['Missing::Model', '5'])
    end
  end

  describe 'a change saved without a version' do
    let(:recorded_title) { version('AttributedArticle', 1, 1, changes: { 'title' => %w[A B] }) }

    it 'splits off what changed after the recorded value' do
      expect(credited(attribution([recorded_title]), row(:changed, 'title', 'A', 'Z')))
        .to eq([[:changed, 'title', 'A', 'B', 1], [:changed, 'title', 'B', 'Z', :unversioned]])
    end

    it 'splits off what changed before the recorded value, when the transaction is whole' do
      moved = version('AttributedArticle', 1, 1, changes: { 'title' => %w[M B] })

      expect(credited(attribution([moved]), row(:changed, 'title', 'A', 'B')))
        .to eq([[:changed, 'title', 'A', 'M', :unversioned], [:changed, 'title', 'M', 'B', 1]])
      expect(credited(attribution([moved], complete: false), row(:changed, 'title', 'A', 'Z')))
        .to eq([[:changed, 'title', 'A', 'B', 1], [:changed, 'title', 'B', 'Z', :unversioned]])
    end

    it 'splits off what changed between two recorded changes' do
      later = version('AttributedArticle', 1, 2, changes: { 'title' => %w[M C] })

      expect(credited(attribution([recorded_title, later]), row(:changed, 'title', 'A', 'C')))
        .to eq([[:changed, 'title', 'A', 'B', 1], [:changed, 'title', 'B', 'M', :unversioned],
                [:changed, 'title', 'M', 'C', 2]])
    end

    # The root's own change surfaces in its own step, so its transaction's
    # earlier versions may already be reported.
    it 'starts from the version that left the starting value, or after one that reached it' do
      later = version('AttributedArticle', 1, 3, changes: { 'title' => %w[X C] })
      read = attribution([later], preceding: [recorded_title])

      expect(credited(read, row(:changed, 'title', 'X', 'C')))
        .to eq([[:changed, 'title', 'X', 'C', 3]])
      expect(credited(attribution([version('AttributedArticle', 1, 3, changes: {})],
                                  preceding: [recorded_title], complete: false),
                      row(:changed, 'title', 'B', 'X')))
        .to eq([[:changed, 'title', 'B', 'X', 3]])
      expect(credited(read, row(:changed, 'title', 'B', 'C')))
        .to eq([[:changed, 'title', 'B', 'X', :unversioned], [:changed, 'title', 'X', 'C', 3]])
      partial = attribution([later], preceding: [recorded_title], complete: false)
      expect(credited(partial, row(:changed, 'title', 'B', 'C')))
        .to eq([[:changed, 'title', 'B', 'X', :unversioned], [:changed, 'title', 'X', 'C', 3]])
    end

    it 'reads on from the last version that reached the starting value' do
      read = attribution([version('AttributedArticle', 1, 1, changes: { 'title' => %w[Q R] }),
                          version('AttributedArticle', 1, 2, changes: { 'title' => %w[A B] }),
                          version('AttributedArticle', 1, 3, changes: { 'title' => %w[X C] })])

      expect(credited(read, row(:changed, 'title', 'B', 'C')))
        .to eq([[:changed, 'title', 'B', 'X', :unversioned], [:changed, 'title', 'X', 'C', 3]])
    end

    it 'joins recorded changes that meet, wherever they fall' do
      read = attribution([version('AttributedArticle', 1, 1, changes: { 'title' => %w[A B] }),
                          version('AttributedArticle', 1, 2, changes: { 'title' => %w[M N] }),
                          version('AttributedArticle', 1, 3, changes: { 'title' => %w[N C] })])

      expect(credited(read, row(:changed, 'title', 'A', 'C')))
        .to eq([[:changed, 'title', 'A', 'B', 1], [:changed, 'title', 'B', 'M', :unversioned],
                [:changed, 'title', 'M', 'C', 3]])
    end

    it 'reads recorded changes that undo each other as no change at all' do
      read = attribution([version('AttributedArticle', 1, 1, changes: { 'title' => %w[X Y] }),
                          version('AttributedArticle', 1, 2, changes: { 'title' => %w[Y X] })])

      expect(credited(read, row(:changed, 'title', 'A', 'Z')))
        .to eq([[:changed, 'title', 'A', 'Z', :unversioned]])
    end

    it "names a member's own record, by its base class, for what changed without a version" do
      note = PaperTrailDiff::RecordReference.new(type: 'AttributedNote', id: 3)
      read = attribution([version('AttributedArticle', 3, 1, changes: { 'title' => %w[A B] }),
                          version('AttributedComment', 7, 2, changes: { 'body' => %w[a b] })])

      [[note, 'title', %w[AttributedArticle 3]], [comment, 'body', %w[AttributedComment 7]]]
        .each do |record, name, identity|
          split = read.call(row(:changed, name, 'a', 'z', record: record)).last
          expect([split.source.item_type, split.source.item_id.to_s]).to eq(identity)
        end
    end

    it 'gives a change its versions recorded and undid to the unversioned source' do
      undone = version('AttributedArticle', 1, 2, changes: { 'title' => %w[B A] })

      expect(credited(attribution([recorded_title, undone]), row(:changed, 'title', 'A', 'Z')))
        .to eq([[:changed, 'title', 'A', 'Z', :unversioned]])
    end

    it 'gives a field no version recorded the unversioned source, when they record it' do
      edit = version('AttributedComment', 7, 2, changes: { 'body' => %w[a b] })

      expect(credited(attribution([recorded_title]), row(:changed, 'summary', nil, 'x')))
        .to eq([[:changed, 'summary', nil, 'x', :unversioned]])
      expect(credited(attribution([edit]), row(:changed, 'rank', 1, 2, record: comment)))
        .to eq([[:changed, 'rank', 1, 2, 2]])
      expect(credited(attribution([recorded_title], complete: false),
                      row(:changed, 'summary', nil, 'x')))
        .to eq([[:changed, 'summary', nil, 'x', 1]])
    end

    it 'names the record and no version, author, event or time' do
      split = attribution([recorded_title]).call(row(:changed, 'title', 'A', 'Z')).last

      expect(split).to be_unversioned
      expect(split.source.to_h(metadata: true)).to eq(
        kind: :unversioned, version_id: nil, item_type: 'AttributedArticle', item_id: 1,
        recorded_at: nil, event: nil, whodunnit: nil, transaction_id: nil,
        record: { type: 'AttributedArticle', id: 1 }, recorded_changes: nil
      )
      expect(attribution([recorded_title]).call(row(:changed, 'title', 'A', 'B')).first)
        .not_to be_unversioned
    end
  end

  describe 'a record that appeared or disappeared' do
    let(:create) do
      version('AttributedComment', 7, 5, event: 'create',
                                         changes: { 'body' => [nil, 'a'], 'flag' => [true, nil] })
    end

    it 'credits a created record, and the fields its create recorded, to its create' do
      sources = [create]

      expect(credited(attribution(sources), row(:added, nil, nil, nil, record: comment)))
        .to eq([[:added, nil, nil, nil, 5]])
      expect(credited(attribution(sources), row(:added, 'body', nil, 'a', record: comment)))
        .to eq([[:added, 'body', nil, 'a', 5]])
      expect(credited(attribution(sources), row(:added, 'state', nil, 'new', record: comment)))
        .to eq([[:added, 'state', nil, 'new', 5]])
    end

    it 'splits off a value set after its create recorded one' do
      expect(credited(attribution([create]), row(:added, 'body', nil, 'z', record: comment)))
        .to eq([[:added, 'body', nil, 'a', 5], [:changed, 'body', 'a', 'z', :unversioned]])
      expect(credited(attribution([create]), row(:added, 'flag', nil, false, record: comment)))
        .to eq([[:added, 'flag', nil, false, :unversioned]])
    end

    it 'follows a created field through what changed after its create' do
      edit = version('AttributedComment', 7, 6, changes: { 'body' => %w[m b] })

      expect(credited(attribution([create, edit]), row(:added, 'body', nil, 'b', record: comment)))
        .to eq([[:added, 'body', nil, 'a', 5], [:changed, 'body', 'a', 'm', :unversioned],
                [:changed, 'body', 'm', 'b', 6]])
    end

    it 'reads the versions from its create on' do
      edit = version('AttributedComment', 7, 6, changes: { 'body' => %w[a b] })
      earlier = version('AttributedComment', 7, 4, changes: { 'body' => %w[q z] })

      expect(credited(attribution([earlier, create, edit]),
                      row(:added, 'body', nil, 'b', record: comment)))
        .to eq([[:added, 'body', nil, 'b', 6]])
    end

    it 'credits a created field to its create when what was recorded is unknown' do
      unread = version('AttributedComment', 7, 5, event: 'create')

      expect(credited(attribution([unread]), row(:added, 'body', nil, 'z', record: comment)))
        .to eq([[:added, 'body', nil, 'z', 5]])
    end

    it 'keeps a record that appeared without its own create on the step source' do
      moved = version('AttributedComment', 7, 5, changes: { 'article_id' => [2, 1] })
      joined = row(:added, 'body', nil, 'a', record: comment)

      expect(attribution([moved]).call(joined)).to eq([joined])
    end

    it 'credits a removed record and its fields to its destroy' do
      destroy = version('AttributedComment', 7, 8, event: 'destroy', changes: {})
      edit = version('AttributedComment', 7, 9, changes: {})
      left = row(:removed, 'body', 'a', nil, record: comment)

      expect(credited(attribution([destroy, edit]), row(:removed, nil, nil, nil, record: comment)))
        .to eq([[:removed, nil, nil, nil, 8]])
      expect(credited(attribution([destroy]), left)).to eq([[:removed, 'body', 'a', nil, 8]])
      expect(attribution([edit]).call(left)).to eq([left])
    end
  end
end
