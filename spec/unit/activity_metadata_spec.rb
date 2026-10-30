# frozen_string_literal: true

RSpec.describe 'activity attribution and serialization' do
  let(:source) do
    PaperTrailDiff::ActivityBoundary.new(
      kind: :version, version_id: 1, item_type: 'Comment', item_id: 7,
      recorded_at: Time.utc(2026), event: 'update', whodunnit: 'alice', transaction_id: 1
    )
  end
  let(:destination) do
    PaperTrailDiff::ActivityBoundary.new(
      kind: :version, version_id: 2, item_type: 'Article', item_id: 3,
      recorded_at: Time.utc(2026) + 1, event: 'update', whodunnit: 'bob', transaction_id: 2
    )
  end
  let(:snapshot) do
    PaperTrailDiff::RecordSnapshot.new(type: 'Article', id: 3, attributes: { title: 'After' })
  end
  let(:step) do
    PaperTrailDiff::ActivityStep.between(
      from_boundary: source, to_boundary: destination,
      from_snapshot: nil, to_snapshot: snapshot, retain: true
    )
  end

  it 'names the source event without asking the caller to choose an endpoint' do
    expect(step.source_boundary).to equal(source)
    expect(step.source_boundary.whodunnit).to eq('alice')
    expect(step.source_boundary.record.to_h).to eq(type: 'Comment', id: 7)
  end

  it 'preserves the default serialized shape and includes metadata only on request' do
    expect(step.to_h.keys).to eq(%i[from to diff])
    expect(step.to_h.fetch(:from).keys).to eq(%i[kind version_id item_type item_id recorded_at])
    payload = step.to_h(metadata: true, snapshots: true)

    expect(payload.fetch(:from)).to include(event: 'update', whodunnit: 'alice', transaction_id: 1)
    expect(payload.fetch(:to)).to include(whodunnit: 'bob', transaction_id: 2)
    expect(payload.fetch(:from_snapshot)).to be_nil
    expect(payload.fetch(:to_snapshot)).to eq(snapshot.to_h)
  end

  it 'forwards serialization options through a combined analysis' do
    analysis = PaperTrailDiff::Analysis.new(diff: step.diff, timeline: [],
                                            activity_timeline: [step])

    expect(analysis.to_h.fetch(:activity_timeline)).to eq([step.to_h])
    expect(analysis.to_h(metadata: true, snapshots: true).fetch(:activity_timeline))
      .to eq([step.to_h(metadata: true, snapshots: true)])
  end

  it 'lists the source as the only source of a step that is not a group' do
    expect(step.sources).to eq([source])
    expect(step.sources).to be_frozen
    expect(step.to_h.keys).to eq(%i[from to diff])
    expect(step.to_h(metadata: true).fetch(:sources)).to eq([source.to_h(metadata: true)])
  end

  it 'lists sources with their metadata even when the step omits it' do
    other = PaperTrailDiff::ActivityStep.new(
      from_boundary: source, to_boundary: destination, diff: step.diff,
      sources: [source, destination]
    )

    expect(other.to_h(metadata: true).fetch(:sources).map { |item| item.fetch(:whodunnit) })
      .to eq(%w[alice bob])
  end

  describe 'recorded changes' do
    def boundary_with(recorded_changes)
      PaperTrailDiff::ActivityBoundary.new(
        kind: :version, version_id: 3, item_type: 'Comment', item_id: 7,
        recorded_at: Time.utc(2026), event: 'update', recorded_changes: recorded_changes
      )
    end

    def recorded
      boundary_with('body' => PaperTrailDiff::ValueChange.new(from: 'a', to: 'b'))
    end

    def nothing
      boundary_with(nil)
    end

    it 'refuses to answer when they were not read, rather than claim nothing was recorded' do
      expect(source.recorded_changes?).to be(false)
      expect { source.recorded_changes }
        .to raise_error(PaperTrailDiff::ConfigurationError,
                        'recorded changes were not read; pass recorded_changes: true')
      expect(source.to_h(metadata: true)).not_to have_key(:recorded_changes)
    end

    it 'returns them, and nil for a version that recorded nothing' do
      expect(recorded.recorded_changes?).to be(true)
      expect(recorded.recorded_changes.fetch('body').to_h).to eq(from: 'a', to: 'b')
      expect(nothing.recorded_changes?).to be(true)
      expect(nothing.recorded_changes).to be_nil
    end

    it 'serializes them with the metadata only' do
      expect(recorded.to_h).not_to have_key(:recorded_changes)
      expect(recorded.to_h(metadata: true).fetch(:recorded_changes))
        .to eq('body' => { from: 'a', to: 'b' })
      expect(nothing.to_h(metadata: true).fetch(:recorded_changes)).to be_nil
    end
  end

  describe 'change rows' do
    def analysis(steps)
      PaperTrailDiff::Analysis.new(diff: step.diff, timeline: [], activity_timeline: steps)
    end

    def labels(rows)
      rows.map { |row| [row.source.whodunnit, row.change, row.attribute] }
    end

    it "attributes a step's rows to its source" do
      expect(labels(step.change_rows))
        .to eq([['alice', :added, nil], ['alice', :added, 'title']])
    end

    it "lists an analysis's rows step by step, and needs its activity timeline" do
      later = PaperTrailDiff::ActivityStep.between(
        from_boundary: destination, to_boundary: destination, from_snapshot: snapshot,
        to_snapshot: nil, retain: false
      )

      expect(labels(analysis([step, later]).change_rows))
        .to eq([['alice', :added, nil], ['alice', :added, 'title'],
                ['bob', :removed, nil], ['bob', :removed, 'title']])
      expect(analysis([step]).change_rows).to be_frozen
      expect { PaperTrailDiff::Analysis.new(diff: step.diff, timeline: []).change_rows }
        .to raise_error(PaperTrailDiff::ConfigurationError, 'change_rows requires activity: true')
    end

    it "keys a scoped analysis's rows like its analyses, deleted roots last" do
      scoped = PaperTrailDiff::ScopedAnalysis.new(
        analyses: { %w[Article 3] => analysis([step]) },
        unreachable: [%w[Article 4], %w[Article 5]],
        deleted: { %w[Article 4] => analysis([]), %w[Article 5] => nil }
      )

      rows = scoped.change_rows
      expect(rows.keys).to eq([%w[Article 3], %w[Article 4]])
      expect(labels(rows.fetch(%w[Article 3]))).to eq(labels(step.change_rows))
      expect(rows.fetch(%w[Article 4])).to eq([])
      expect(rows).to be_frozen
    end
  end
end
