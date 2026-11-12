# frozen_string_literal: true

RSpec.describe PaperTrailDiff::CollectionIdentityIndex do
  def record(id, type: 'Comment', body: 'same')
    PaperTrailDiff::RecordSnapshot.new(type: type, id: id, attributes: { 'body' => body })
  end

  # A few records are read through and more are searched. Either way finds
  # the same record, so each example runs on a collection of each size.
  shared_examples 'a collection in order' do |padding|
    # Records that sort after every other, with ids no example asks for.
    define_method(:build) do |*records|
      described_class.new(records + Array.new(padding) { |id| record(100 + id, type: 'Zzz') })
    end

    # In type, then id, order, as an association snapshot holds its records.
    let(:index) { build(record(1), record(7), record('a'), record(1, type: 'Post')) }

    # Version ids can arrive as strings even when the column is an integer.
    it 'finds a position by type and id, matching ids by their text' do
      expect(index.position('Comment', 1)).to eq(0)
      expect(index.position('Comment', '1')).to eq(0)
      expect(index.position('Comment', '7')).to eq(1)
      expect(index.position('Comment', 'a')).to eq(2)
      expect(index.position('Comment', :a)).to eq(2)
      expect(index.position(:Post, 1)).to eq(3)
    end

    it 'finds no position for a record the collection does not hold' do
      expect(index.position('Comment', 2)).to be_nil
      expect(index.position('Comment', 8)).to be_nil
      expect(index.position('Comment', '01')).to be_nil
      expect(index.position('Post', 7)).to be_nil
      expect(index.position('Video', 1)).to be_nil
      expect(index.position('Comment', nil)).to be_nil
      expect(build.position('Comment', 1)).to be_nil
    end

    it 'finds a string id that reads as a number' do
      strings = build(record('10'), record('9'))

      expect(strings.position('Comment', 9)).to eq(1)
      expect(strings.position('Comment', '10')).to eq(0)
    end

    it 'finds a position by id alone only when one record has that id' do
      expect(index.position_for_id(7)).to eq(1)
      expect(index.position_for_id('7')).to eq(1)
      expect(index.position_for_id('a')).to eq(2)
      expect(index.position_for_id(1)).to be_nil
      expect(index.position_for_id(2)).to be_nil
    end

    it 'finds a position by id alone in the last type it holds' do
      last = build(record(1), record(2, type: 'Post'), record(3, type: 'Video'))

      expect(last.position_for_id(3)).to eq(2)
      expect(last.position_for_id(2)).to eq(1)
      expect(last.position_for_id(1)).to eq(0)
    end

    it 'keeps an id ambiguous once a third record shares it' do
      shared = build(record(1), record(1, type: 'Post'), record(1, type: 'Video'))

      expect(shared.position_for_id(1)).to be_nil
    end

    it 'says where a record it does not hold goes to keep the order' do
      expect(index.insertion('Comment', 0)).to eq(0)
      expect(index.insertion('Comment', 3)).to eq(1)
      expect(index.insertion('Comment', 'b')).to eq(3)
      expect(index.insertion('Post', 0)).to eq(3)
      expect(index.insertion('Video', 1)).to eq(4)
      expect(index.insertion('Comment', 7)).to eq(1)
    end

    it 'finds the number before the string that prints like it' do
      both = build(record(1), record('1'))

      expect([both.position('Comment', 1), both.position('Comment', '1')]).to eq([0, 0])
    end
  end

  context 'with few enough records to read through' do
    it_behaves_like 'a collection in order', 0
  end

  context 'with more records than are read through' do
    it_behaves_like 'a collection in order', described_class::READ_THROUGH
  end

  it 'reads through up to eight records, and searches more' do
    allow(PaperTrailDiff::Support).to receive(:sortable_identity).and_call_original
    fewer, few, more = [7, 8, 9].map do |count|
      described_class.new(Array.new(count) { |id| record(id) })
    end

    expect(fewer.position('Comment', 6)).to eq(6)
    expect(few.position('Comment', 7)).to eq(7)
    expect(PaperTrailDiff::Support).not_to have_received(:sortable_identity)
    expect(more.position('Comment', 8)).to eq(8)
    expect(PaperTrailDiff::Support).to have_received(:sortable_identity).at_least(:once)
  end

  # A table of positions reads every record; a replay asks once per event.
  it 'searches the order instead of reading every record' do
    wide = described_class.new(Array.new(1_024) { |id| record(id) })
    allow(PaperTrailDiff::Support).to receive(:sortable_identity).and_call_original

    expect(wide.position('Comment', 700)).to eq(700)
    expect(wide.position_for_id(701)).to eq(701)

    expect(PaperTrailDiff::Support).to have_received(:sortable_identity).at_most(50).times
  end

  it 'is frozen' do
    expect(described_class.new([record(1)])).to be_frozen
  end
end
