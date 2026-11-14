# frozen_string_literal: true

RSpec.describe PaperTrailDiff::TransactionEnds do
  let(:base) { Time.utc(2032, 1, 1, 12) }

  before do
    stub_const('EndsVersion', Struct.new(:id, :transaction_id, :created_at))
    stub_const('EndsOtherVersion', Class.new(EndsVersion))
    stub_const('EndsRow', Class.new(Struct.new(:id, :transaction_id, :created_at, :item_type)) do
      def self.table_name = 'versions'
    end)
  end

  # A version row, as a boundary is told from a live record.
  def row(id, transaction_id)
    EndsRow.new(id, transaction_id, base + id, 'Shape')
  end

  # A version saved `id` seconds in, so ids order as times do.
  def version(id, transaction_id, table: EndsVersion, at: id)
    table.new(id, transaction_id, base + at)
  end

  def ordered(versions)
    ends = described_class.new(versions, {})
    versions.sort_by { |each| ends.sort_key(each) }.map(&:id)
  end

  # With recorded ends, a transaction they do not name is placed among the
  # versions held.
  it 'places each version at the last its transaction saved, whatever order they are given in' do
    first = version(1, 7)
    other = version(2, 8)
    last = version(3, 7)
    ends = described_class.new([last, other, first], {})

    expect([first, other, last].map { |each| ends.last(each) }).to eq([last, other, last])
    expect(ends).to be_frozen
  end

  # Read without recorded ends, as a root alone is, every version is where
  # it was saved.
  it 'keeps every version where it is without recorded ends' do
    first = version(1, 7)
    other = version(2, 8)
    ends = described_class.new([first, other, version(3, 7)])

    expect([ends.last(first), ends.last(other)]).to eq([first, other])
  end

  it 'keeps a version outside a transaction, or of one it was not given, where it is' do
    alone = version(1, nil)
    unknown = version(2, 9)
    ends = described_class.new([alone, version(3, 7), version(4, nil)], {})

    expect([ends.last(alone), ends.last(unknown)]).to eq([alone, unknown])
    expect(ends.sort_key(unknown).first).to eq(ends.sort_key(unknown).last)
  end

  it 'orders transactions by where they end, and the versions of each as they were saved' do
    versions = [version(1, 7), version(2, 8), version(3, nil), version(4, 8), version(5, 7),
                version(6, 9)]

    expect(ordered(versions)).to eq([3, 2, 4, 1, 5, 6])
    expect(ordered(versions.reverse)).to eq([3, 2, 4, 1, 5, 6])
  end

  it 'places a version at one saved at the same instant with a later id' do
    first = version(1, 7)
    tied = version(2, 7, at: 1)

    expect(described_class.new([tied, first], {}).last(first)).to eq(tied)
    expect(described_class.new([first, tied], {}).last(tied)).to eq(tied)
  end

  it 'tells transactions numbered alike in two version tables apart' do
    here = version(1, 7)
    there = version(2, 7, table: EndsOtherVersion)
    ends = described_class.new([here, there, version(3, 7)], {})

    expect(ends.last(here).id).to eq(3)
    expect(ends.last(there)).to eq(there)
  end

  it 'places a transaction at the version recorded as its last, held or not' do
    first = version(1, 7)
    other = version(2, 8)
    last = version(3, 7)
    recorded = version(9, 7)
    ends = described_class.new([first, other, last], { ['EndsVersion', 7] => recorded })

    expect([first, other, last].map { |each| ends.last(each) }).to eq([recorded, other, recorded])
    expect(ends.sort_key(first)).to eq([PaperTrailDiff::Support.chronological_version_key(recorded),
                                        PaperTrailDiff::Support.chronological_version_key(first)])
    expect([last, other, first].sort_by { |each| ends.sort_key(each) }).to eq([other, first, last])
  end

  describe '#target' do
    it 'places a version boundary at the last version of its transaction, and when it was saved' do
      first = row(1, 7)
      last = row(3, 7)
      ends = described_class.new([first, row(2, 8), last], {})

      expect(ends.target(first)).to eq([last, base + 3])
      expect(ends.target(first).first).to equal(last)
    end

    it 'places a live record where it was read, whatever transaction number it carries' do
      record = version(1, 7)
      ends = described_class.new([row(1, 7), row(3, 7)], {})

      expect(ends.target(record)).to eq([record, base + 1])
      expect(ends.target(record).first).to equal(record)
    end

    it 'keeps the answer of the boundary asked last, and of no other' do
      first = row(1, 7)
      other = row(2, 8)
      ends = described_class.new([first, other, row(3, 7)], {})
      answer = ends.target(first)

      expect(ends.target(first)).to equal(answer)
      expect(ends.target(other)).to eq([other, base + 2])
      expect(ends.target(other)).to equal(ends.target(other))
      expect(ends.target(first)).to eq(answer)
      expect(ends.target(first)).not_to equal(answer)
    end

    it 'tells two live records that compare equal apart' do
      record = version(1, nil)
      twin = version(1, nil)
      ends = described_class.new([], {})

      expect(ends.target(record).first).to equal(record)
      expect(ends.target(twin).first).to equal(twin)
    end
  end
end
