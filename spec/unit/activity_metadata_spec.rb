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
end
