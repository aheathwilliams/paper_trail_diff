# frozen_string_literal: true

RSpec.describe PaperTrailDiff::CollectionIdentityIndex do
  def record(id, type: 'Comment', body: 'same')
    PaperTrailDiff::RecordSnapshot.new(type: type, id: id, attributes: { 'body' => body })
  end

  # Version ids can arrive as strings even when the column is an integer.
  let(:index) { described_class.new([record(1), record('a'), record(1, type: 'Post'), record(7)]) }

  it 'finds a position by type and id, matching ids by their text' do
    expect(index.position('Comment', 1)).to eq(0)
    expect(index.position('Comment', '1')).to eq(0)
    expect(index.position('Comment', 'a')).to eq(1)
    expect(index.position('Post', 1)).to eq(2)
    expect(index.position('Comment', 2)).to be_nil
  end

  it 'finds a position by id alone only when one record has that id' do
    expect(index.position_for_id(7)).to eq(3)
    expect(index.position_for_id('7')).to eq(3)
    expect(index.position_for_id('a')).to eq(1)
    expect(index.position_for_id(1)).to be_nil
    expect(index.position_for_id(2)).to be_nil
  end

  it 'keeps an id ambiguous once a third record shares it' do
    shared = described_class.new([record(1), record(1, type: 'Post'), record(1, type: 'Video')])

    expect(shared.position_for_id(1)).to be_nil
  end

  it 'rejects two records with the same identity' do
    expect { described_class.new([record(1), record(2), record(1, body: 'twin')]) }
      .to raise_error(ArgumentError, 'duplicate record identity: ["Comment", 1]')
  end

  it 'is frozen' do
    expect(index).to be_frozen
  end
end
