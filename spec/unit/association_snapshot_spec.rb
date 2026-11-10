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

    # A replay makes one transition per event, so reading every record's
    # place in the order again for each would cost its events times its size.
    it 'takes the records as in order already' do
      wide = described_class.new(kind: :has_many, records: Array.new(256) { |id| record(id) })
      edited = wide.records.dup
      edited[100] = record(100)
      allow(PaperTrailDiff::Support).to receive(:sortable_identity).and_call_original

      to = wide.transition_to(edited, before: wide.records.fetch(100), after: edited.fetch(100))

      expect(PaperTrailDiff::Support).to have_received(:sortable_identity).at_most(20).times
      expect(to.records).to eq(edited).and be_frozen
    end

    it 'keeps the records as given, in the order they came' do
      to = from.transition_to([record(2), record(1)], before: nil, after: nil)

      expect(identities(to)).to eq([['Comment', 2], ['Comment', 1]])
    end

    it 'names the record that changed to the snapshot it came from alone' do
      added = record(3)
      to = from.transition_to(from.records + [added], before: nil, after: added)

      twin = described_class.new(kind: :has_many, records: from.records)
      unnamed = from.transition_to(from.records, before: nil, after: nil)

      expect(to.transition_from(from)).to have_attributes(before: nil, after: added)
      expect(to.transition_from(twin)).to be_nil
      expect(unnamed.transition_from(from)).to be_nil
    end
  end

  describe '#position' do
    let(:snapshot) do
      described_class.new(kind: :has_many,
                          records: [record(2, type: 'Video'), record(10), record(2)])
    end

    it 'finds a record where the order put it' do
      expect(snapshot.position('Comment', 10)).to eq(1)
      expect(snapshot.position('Video', '2')).to eq(2)
      expect(snapshot.position('Comment', 3)).to be_nil
    end

    it 'finds a record by id alone when only one has it' do
      expect(snapshot.position_for_id(10)).to eq(1)
      expect(snapshot.position_for_id(2)).to be_nil
    end
  end

  describe '#validate_unique_identities!' do
    # Stand-ins that count how often their identity is read.
    def counted(id, reads)
      Struct.new(:type, :id, :reads) do
        def identity
          reads << id
          [type, id]
        end
      end.new('Comment', id, reads)
    end

    it 'accepts distinct records' do
      snapshot = described_class.new(kind: :has_many, records: [record(1), record(2)])

      expect(snapshot.validate_unique_identities!).to be_nil
    end

    it 'rejects two records with the same identity' do
      twins = described_class.new(kind: :has_many, records: [record(1), record(2), record(1)])

      expect { twins.validate_unique_identities! }
        .to raise_error(ArgumentError, 'duplicate record identity: ["Comment", 1]')
      expect { twins.validate_unique_identities! }.to raise_error(ArgumentError)
    end

    it 'tells a number from the string that prints like it' do
      snapshot = described_class.new(kind: :has_many, records: [record(1), record('1')])

      expect(snapshot.validate_unique_identities!).to be_nil
    end

    # A transition cannot repeat an identity, and a replay makes one per
    # event: reading the whole collection for each cost its events times its
    # size.
    it 'reads a collection once however many transitions follow it' do
      reads = []
      first = described_class.new(kind: :has_many, records: [counted(1, reads), counted(2, reads)])
      first.validate_unique_identities!
      checked = reads.size
      joined = counted(3, reads)

      second = first.transition_to(first.records + [joined], before: nil, after: joined)
      second.validate_unique_identities!
      first.validate_unique_identities!

      expect(checked).to be > 0
      expect(reads.size).to eq(checked)
    end

    it 'checks a transition whose origin was never checked' do
      first = described_class.new(kind: :has_many, records: [record(1), record(2)])
      twin = record(2)

      second = first.transition_to(first.records + [twin], before: nil, after: twin)

      expect { second.validate_unique_identities! }
        .to raise_error(ArgumentError, /duplicate record identity/)
    end
  end
end
