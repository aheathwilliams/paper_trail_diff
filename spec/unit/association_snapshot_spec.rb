# frozen_string_literal: true

RSpec.describe PaperTrailDiff::AssociationSnapshot do
  def record(id, type: 'Comment')
    PaperTrailDiff::RecordSnapshot.new(type: type, id: id, attributes: {})
  end

  def identities(snapshot)
    snapshot.records.map { |each| [each.type, each.id] }
  end

  # Whatever order they were read in, as the reference promises.
  it 'holds its records by type, then naturally by id' do
    snapshot = described_class.new(kind: :has_many, records: [record(10), record('b'),
                                                              record(2, type: 'Video'), record(2)])

    expect(identities(snapshot))
      .to eq([['Comment', 2], ['Comment', 10], %w[Comment b], ['Video', 2]])
    expect(snapshot.records).to be_frozen
  end

  it 'keeps records already in order as given' do
    records = [record(1), record(2)].freeze

    expect(described_class.new(kind: :has_many, records: records).records).to equal(records)
  end

  describe '#transition_to' do
    let(:from) { described_class.new(kind: :has_many, records: [record(1), record(2)]) }

    # A replay makes one transition per event, so checking the order of a
    # collection that kept every identity in its place would cost its events
    # times its size.
    it 'takes a collection that kept its membership as in order already' do
      edited = [from.records.first, record(2)]
      allow(PaperTrailDiff::Support).to receive(:sortable_identity).and_call_original

      to = from.transition_to(edited, before: from.records.last, after: edited.last,
                                      membership_preserved: true)

      expect(PaperTrailDiff::Support).not_to have_received(:sortable_identity)
      expect(to.records).to eq(edited).and be_frozen
    end

    it 'orders a collection whose membership changed' do
      added = record(0)

      to = from.transition_to(from.records + [added], before: nil, after: added,
                                                      membership_preserved: false)

      expect(identities(to)).to eq([['Comment', 0], ['Comment', 1], ['Comment', 2]])
    end
  end
end
