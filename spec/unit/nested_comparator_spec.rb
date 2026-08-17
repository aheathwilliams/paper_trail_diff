# frozen_string_literal: true

RSpec.describe PaperTrailDiff::NestedComparator do
  def changes(from_value, to_value)
    described_class.call(from_value, to_value).transform_values(&:to_h)
  end

  it 'reports the keys that changed rather than the whole blob' do
    from_value = { 'theme' => 'dark', 'limits' => { 'max' => 10, 'min' => 1 } }
    to_value = { 'theme' => 'light', 'limits' => { 'max' => 20, 'min' => 1 } }

    expect(changes(from_value, to_value)).to eq(
      ['theme'] => { from: 'dark', to: 'light' },
      %w[limits max] => { from: 10, to: 20 }
    )
  end

  it 'reads a column that stores JSON as text' do
    expect(changes('{"mode":"fast","retries":3}', '{"mode":"slow","retries":3}'))
      .to eq(['mode'] => { from: 'fast', to: 'slow' })
  end

  # `{"a": null}` and `{}` mean different things in JSON, and an audit trail
  # that showed them the same way would be lying about one of them.
  it 'distinguishes a key that went missing from one set to null' do
    result = changes(
      { 'removed' => 2, 'nulled' => 3 },
      { 'nulled' => nil, 'added' => 9 }
    )

    expect(result.fetch(['nulled'])).to eq(from: 3, to: nil)
    expect(result.fetch(['removed'])[:to]).to be(described_class::ABSENT)
    expect(result.fetch(['added'])[:from]).to be(described_class::ABSENT)
  end

  # Elements carry no identity, so an insertion at the front would make every
  # later index look changed.
  it 'reports an array whole instead of by index' do
    expect(changes({ 'l' => %w[a b c] }, { 'l' => %w[z a b c] }))
      .to eq(['l'] => { from: %w[a b c], to: %w[z a b c] })
  end

  # Host names and locales routinely contain dots, so a joined path could not
  # say which of these two changed.
  it 'keeps a dotted key distinct from a nested one' do
    result = changes(
      { 'a.b' => 1, 'a' => { 'b' => 1 } },
      { 'a.b' => 2, 'a' => { 'b' => 3 } }
    )

    expect(result.fetch(['a.b'])).to eq(from: 1, to: 2)
    expect(result.fetch(%w[a b])).to eq(from: 1, to: 3)
  end

  it 'reports nothing when the two sides are not both readable structures' do
    expect(described_class.call('not json', { 'a' => 1 })).to eq({})
    expect(described_class.call('{oops', '{nope')).to eq({})
    expect(described_class.call(nil, { 'a' => 1 })).to eq({})
    expect(described_class.call('[1,2]', '[1,3]')).to eq({})
  end

  it 'reports nothing when the structures are equal' do
    expect(described_class.call({ 'a' => { 'b' => 1 } }, { 'a' => { 'b' => 1 } })).to eq({})
  end

  it 'orders paths so a report reads the same twice' do
    from_value = { 'z' => 1, 'a' => 2, 'm' => 3 }
    to_value = { 'z' => 9, 'a' => 9, 'm' => 9 }

    expect(described_class.call(from_value, to_value).keys).to eq([['a'], ['m'], ['z']])
  end

  it 'returns a frozen result with frozen paths' do
    result = described_class.call({ 'a' => 1 }, { 'a' => 2 })

    expect(result).to be_frozen
    expect(result.keys.first).to be_frozen
  end

  describe 'PaperTrailDiff.nested_changes' do
    it 'accepts the ValueChange an attribute diff already produced' do
      change = PaperTrailDiff::ValueChange.new(from: { 'a' => 1 }, to: { 'a' => 2 })

      expect(PaperTrailDiff.nested_changes(change).fetch(['a']).to_h).to eq(from: 1, to: 2)
    end

    it 'accepts a bare pair' do
      expect(PaperTrailDiff.nested_changes({ 'a' => 1 }, { 'a' => 2 }).keys).to eq([['a']])
    end

    # ActiveSupport defines String#from, so duck-typing on `from` would read a
    # plain string as though it were a change.
    it 'does not mistake a string for a change object' do
      expect(PaperTrailDiff.nested_changes('{"a":1}', '{"a":2}').fetch(['a']).to_h)
        .to eq(from: 1, to: 2)
    end
  end
end
