# frozen_string_literal: true

require 'json'
require_relative '../support/snapshot_cases'

# Properties every nested comparison must have, checked over generated JSON
# values (SnapshotCases::Json) rather than chosen examples.
RSpec.describe PaperTrailDiff::NestedComparator do
  def each_pair
    SnapshotCases.each do |random, size, label|
      json = SnapshotCases::Json.new(random, size)
      from = json.column
      to = json.edit(from)
      yield from, to, "#{label}\nfrom: #{from.inspect}\nto:   #{to.inspect}"
    end
  end

  def changes(from, to)
    described_class.call(from, to).transform_values(&:to_h)
  end

  # The value the changes lead to from `from`: each changed path set to its
  # new value, or removed where the key went.
  def apply(from, changes)
    return changes.fetch([]).fetch(:to) if changes.key?([])

    changes.each_with_object(deep_copy(from)) do |(path, change), value|
      parent = path[0...-1].inject(value) { |hash, key| hash.fetch(key) }
      to = change.fetch(:to)
      to.equal?(described_class::ABSENT) ? parent.delete(path.last) : parent[path.last] = to
    end
  end

  def invert(changes)
    changes.transform_values do |change|
      inverted = change.merge(from: change.fetch(:to), to: change.fetch(:from))
      next inverted unless change.key?(:added)

      inverted.merge(added: change.fetch(:removed), removed: change.fetch(:added))
    end
  end

  def deep_copy(value)
    case value
    when Hash then value.to_h { |key, item| [key, deep_copy(item)] }
    when Array then value.map { |item| deep_copy(item) }
    else value
    end
  end

  # Symbol keys for every Hash, at any depth and inside arrays.
  def symbolize(value)
    case value
    when Hash then value.to_h { |key, item| [key.to_sym, symbolize(item)] }
    when Array then value.map { |item| symbolize(item) }
    else value
    end
  end

  # A value reported whole keeps the keys it was given, so these compare
  # with every key read as a string.
  def stringify(value)
    case value
    when Hash then value.to_h { |key, item| [key.is_a?(Symbol) ? key.to_s : key, stringify(item)] }
    when Array then value.map { |item| stringify(item) }
    else value
    end
  end

  describe 'properties' do
    it 'reports nothing between a value and an equal copy' do
      each_pair do |from, to, label|
        [from, to].each do |value|
          expect(changes(value, deep_copy(value))).to eq({}), -> { label }
        end
      end
    end

    it 'reports every change, and nothing else, that leads from one value to the other' do
      each_pair do |from, to, label|
        found = changes(from, to)

        expect(apply(from, found)).to eq(to), -> { "#{label}\nchanges: #{found}" }
      end
    end

    it 'reports the opposite change when compared the other way' do
      each_pair do |from, to, label|
        found = changes(from, to)

        expect(changes(to, from)).to eq(invert(found)), -> { "#{label}\nchanges: #{found}" }
      end
    end

    it 'reads the same changes from JSON text and from symbol keys' do
      each_pair do |from, to, label|
        found = changes(from, to)

        expect(changes(JSON.generate(from), JSON.generate(to))).to eq(found), -> { label }
        symbolized = changes(symbolize(from), to).transform_values do |change|
          change.transform_values { |item| stringify(item) }
        end
        expect(symbolized).to eq(found), -> { label }
      end
    end

    it 'reports only real changes, frozen and in path order' do
      each_pair do |from, to, label|
        result = described_class.call(from, to)

        expect(result.keys).to eq(result.keys.sort), -> { label }
        expect([result, *result.keys]).to all(be_frozen), -> { label }
        expect(result.values.select { |change| change.from == change.to }).to eq([]), -> { label }
      end
    end

    # Elements carry no identity, so an array change is a change of
    # membership, counted with repeats.
    it 'reports an array change as the elements gained and lost' do
      each_pair do |from, to, label|
        described_class.call(from, to).each_value do |change|
          next unless change.is_a?(PaperTrailDiff::ArrayChange)

          gained = surplus(change.to, change.from)
          lost = surplus(change.from, change.to)
          expect([change.added.tally, change.removed.tally]).to eq([gained, lost]), -> { label }
          expect(change.reordered?).to eq(gained.empty? && lost.empty?), -> { label }
        end
      end
    end
  end

  # How many more times each element appears in `left` than in `right`.
  def surplus(left, right)
    counts = right.tally
    left.tally.filter_map do |element, count|
      extra = count - counts.fetch(element, 0)
      [element, extra] if extra.positive?
    end.to_h
  end
end
