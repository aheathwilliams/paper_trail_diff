# frozen_string_literal: true

RSpec.describe PaperTrailDiff::TransactionEnds do
  let(:base) { Time.utc(2032, 1, 1, 12) }

  before do
    stub_const('EndsVersion', Struct.new(:id, :transaction_id, :created_at))
    stub_const('EndsOtherVersion', Class.new(EndsVersion))
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
end
