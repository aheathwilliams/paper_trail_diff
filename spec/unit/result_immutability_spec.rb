# frozen_string_literal: true

RSpec.describe 'result isolation' do
  it 'copies mutable descendants even when the caller freezes their container' do
    text = +'Original'
    input = { 'tags' => [text].freeze }.freeze
    snapshot = PaperTrailDiff::RecordSnapshot.new(type: 'Example', id: 1,
                                                  attributes: { 'data' => input })
    change = PaperTrailDiff::ValueChange.new(from: input, to: {})
    text.replace('Changed')

    expect(snapshot.attributes.fetch('data')).to eq('tags' => ['Original'])
    expect(change.from).to eq('tags' => ['Original'])
    expect { change.from.fetch('tags').first.replace('Mutated') }.to raise_error(FrozenError)
  end

  it 'freezes every component of nested diff paths and empty results' do
    result = PaperTrailDiff.nested_changes({ outer: { inner: 1 } }, { outer: { inner: 2 } })

    expect { result.keys.first.last.replace('changed') }.to raise_error(FrozenError)
    expect(result.fetch(%w[outer inner]).to_h).to eq(from: 1, to: 2)
    expect(PaperTrailDiff.nested_changes(nil, {})).to be_frozen
  end
end
