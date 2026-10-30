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
end
