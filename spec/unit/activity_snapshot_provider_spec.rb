# frozen_string_literal: true

RSpec.describe PaperTrailDiff::ActivitySnapshotProvider do
  let(:store) { instance_double(PaperTrailDiff::HistoricalSnapshotStore) }
  let(:provider) do
    described_class.new(store: store, snapshotter: ->(*) {}, refresher: ->(_snapshots) {})
  end
  let(:versions) { [Struct.new(:created_at).new(Time.now.utc)] }

  # A batch prepares one history for its roots, and building the snapshots
  # and their refresher again for each root cost a few percent of a batch.
  it 'shares snapshots between consecutive roots with one history, and only those' do
    batch = instance_double(PaperTrailDiff::PreparedHistory)
    other = instance_double(PaperTrailDiff::PreparedHistory)
    # Without associations there is no history, from the first root on.
    allow(store).to receive(:prepare).and_return(nil, nil, batch, batch, other)

    none, again, first, second, third = Array.new(5) { provider.prepare(:record, versions) }

    expect(none).to be_a(PaperTrailDiff::PreparedActivitySnapshots)
    expect(none.history).to be_nil
    expect(again).to equal(none)
    expect(first.history).to equal(batch)
    expect(second).to equal(first)
    expect(third).not_to equal(first)
    expect(third.history).to equal(other)
  end
end
