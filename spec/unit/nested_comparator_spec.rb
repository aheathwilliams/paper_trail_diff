# frozen_string_literal: true

RSpec.describe PaperTrailDiff::NestedComparator do
  it 'matches Ruby symbol keys to JSON string keys at every depth' do
    expect(changes({ outer: { count: 1 } }, { 'outer' => { 'count' => 2 } }))
      .to eq(%w[outer count] => { from: 1, to: 2 })
    expect(described_class.call({ a: 1 }, { 'a' => 1 })).to be_empty
    expect(changes({ 'outer' => { 'count' => 1 } }, { outer: { count: 2 } }))
      .to eq(%w[outer count] => { from: 1, to: 2 })
  end

  # Serialized columns commonly read back as a Hash subclass.
  it 'looks inside hash subclasses such as HashWithIndifferentAccess' do
    indifferent = ->(hash) { ActiveSupport::HashWithIndifferentAccess.new(hash) }

    expect(changes(indifferent.call('a' => { 'b' => 1 }), indifferent.call('a' => { 'b' => 2 })))
      .to eq(%w[a b] => { from: 1, to: 2 })
  end

  it 'reports a nested object replaced by a plain value as a whole-value change' do
    expect(changes({ 'a' => { 'b' => 1 } }, { 'a' => 5 }))
      .to eq(['a'] => { from: { 'b' => 1 }, to: 5 })
    expect(changes({ 'a' => 5 }, { 'a' => { 'b' => 1 } }))
      .to eq(['a'] => { from: 5, to: { 'b' => 1 } })
  end

  it 'keeps looking after a key that did not change' do
    expect(changes({ 'a' => 1, 'b' => 1, 'c' => 1 }, { 'a' => 1, 'b' => 2, 'c' => 3 }).keys)
      .to eq([['b'], ['c']])
  end

  it 'rejects ambiguous normalized keys instead of overwriting a change' do
    expect { described_class.call({ a: 1, 'a' => 2 }, { a: 3 }) }
      .to raise_error(PaperTrailDiff::AmbiguousNestedKeyError,
                      'duplicate nested key after normalization: "a"')
  end

  it 'keeps the whole-value diff available when nested keys are ambiguous' do
    before = PaperTrailDiff::RecordSnapshot.new(
      type: 'Example', id: 1, attributes: { config: { a: 1, 'a' => 2 } }
    )
    after = PaperTrailDiff::RecordSnapshot.new(
      type: 'Example', id: 1, attributes: { config: { a: 3 } }
    )
    diff = PaperTrailDiff::Engine.compare(before, after)

    expect(diff.to_h.fetch(:attributes).fetch('config'))
      .to eq(from: { a: 1, 'a' => 2 }, to: { a: 3 })
    expect { PaperTrailDiff.nested_changes(diff.attributes.fetch('config')) }
      .to raise_error(PaperTrailDiff::AmbiguousNestedKeyError)
  end

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
    text = Class.new(String) # such as ActiveSupport::SafeBuffer
    expect(changes(text.new('{"mode":"fast"}'), text.new('{"mode":"slow"}')))
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
    expect(described_class::ABSENT.inspect).to eq('#<PaperTrailDiff absent>')
    expect(described_class::ABSENT.to_s).to eq('absent')
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

  describe 'arrays' do
    def array_change(from_value, to_value)
      described_class.call({ 'k' => from_value }, { 'k' => to_value }).fetch(['k'])
    end

    # Position would be the obvious thing to report and the wrong one: an
    # insertion at the front makes every later index look changed, so one
    # insertion would read as several edits.
    it 'reports what was added and removed rather than what moved' do
      change = array_change(%w[apollo nasa], %w[saturn apollo nasa])

      expect(change).to be_a(PaperTrailDiff::ArrayChange)
      expect(change.added).to eq(['saturn'])
      expect(change.removed).to eq([])
      expect(change.reordered?).to be(false)
    end

    it 'reports a removal' do
      change = array_change(%w[a b c], %w[a c])

      expect(change.removed).to eq(['b'])
      expect(change.added).to eq([])
    end

    it 'reports an exchange as both an addition and a removal' do
      change = array_change(%w[a b], %w[a z])

      expect(change.added).to eq(['z'])
      expect(change.removed).to eq(['b'])
    end

    # Membership cannot see this, so it is named rather than passed over.
    it 'names a reordering, which membership alone cannot show' do
      change = array_change(%w[a b c], %w[c a b])

      expect(change.reordered?).to be(true)
      expect(change.added).to eq([])
      expect(change.removed).to eq([])
      expect(change.from).to eq(%w[a b c])
      expect(change.to).to eq(%w[c a b])
    end

    it 'respects duplicates rather than treating the array as a set' do
      expect(array_change(%w[a a b], %w[a b]).removed).to eq(['a'])
      expect(array_change(%w[a b], %w[a a b]).added).to eq(['a'])
    end

    # Saying which field of which object changed would need a pairing of
    # before-elements with after-elements that nothing in the value licenses.
    it 'reports an element that is itself a structure whole' do
      change = array_change([{ 'id' => 1 }], [{ 'id' => 1 }, { 'id' => 2 }])

      expect(change.added).to eq([{ 'id' => 2 }])
      expect(change.removed).to eq([])
    end

    it 'falls back to a plain value change when only one side is an array' do
      expect(array_change(%w[a], 'a')).to be_a(PaperTrailDiff::ValueChange)
    end

    it 'serializes membership alongside the whole values' do
      expect(array_change(%w[a b], %w[b a]).to_h).to eq(
        from: %w[a b], to: %w[b a], added: [], removed: [], reordered: true
      )
    end

    it 'is frozen, and reports equal arrays as no change at all' do
      expect(array_change(%w[a b], %w[b a])).to be_frozen
      expect(described_class.call({ 'k' => %w[a b] }, { 'k' => %w[a b] })).to eq({})
    end
  end

  it 'reports nothing when the two sides are not both readable structures' do
    expect(described_class.call('not json', { 'a' => 1 })).to eq({})
    expect(described_class.call('{oops', '{nope')).to eq({})
    expect(described_class.call(nil, { 'a' => 1 })).to eq({})
    expect(described_class.call('[1,2]', '[1,3]')).to eq({})
    expect(described_class.call({ 'a' => 1 }, 'not json')).to eq({})
    expect(described_class.call({ 'a' => 1 }, 5)).to eq({})
    expect(described_class.call(nil, nil)).to be_frozen
  end

  it 'compares an array with a non-array as a whole value, not by membership' do
    expect(described_class.call({ 'k' => 'x' }, { 'k' => ['x'] }).fetch(['k']))
      .to be_a(PaperTrailDiff::ValueChange)
    expect(described_class.call({ 'k' => ['x'] }, { 'k' => 'x' }).fetch(['k']))
      .to be_a(PaperTrailDiff::ValueChange)
  end

  it 'compares array subclasses by membership' do
    list = Class.new(Array)

    change = described_class.call({ 'k' => list.new(%w[a]) }, { 'k' => list.new(%w[a b]) })

    expect(change.fetch(['k']).added).to eq(['b'])
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
