# frozen_string_literal: true

require_relative '../support/snapshot_cases'
require_relative '../support/diff_algebra'

# Properties every comparison must have, checked over generated snapshot
# pairs (spec/support/snapshot_cases.rb) rather than chosen examples. A
# failure names the case that reproduces it; the cases grow from the
# smallest, so the first failure is a small one.
RSpec.describe PaperTrailDiff::Engine do
  def each_pair
    SnapshotCases.each do |random, size, label|
      generator = SnapshotCases::Generator.new(random, size)
      from = random.rand < 0.05 ? nil : generator.root
      to = generator.edit(from)
      yield from, to, generator, label
    end
  end

  def compare(from, to)
    described_class.compare(from, to)
  end

  def describe_case(label, from, to)
    "#{label}\nfrom: #{from&.to_h.inspect}\nto:   #{to&.to_h.inspect}"
  end

  describe 'properties' do
    it 'reports nothing between a snapshot and an equal one built apart' do
      each_pair do |from, to, generator, label|
        [from, to].each do |snapshot|
          diff = compare(snapshot, generator.copy(snapshot))
          expect(diff).to be_empty, -> { "#{describe_case(label, from, to)}\ndiff: #{diff.to_h}" }
        end
      end
    end

    # Applying a diff to the snapshot it starts from gives the one it ends at,
    # so a diff misses no change and reports none wrongly.
    it 'reports every change, and nothing else, that leads from one snapshot to the other' do
      each_pair do |from, to, _generator, label|
        diff = compare(from, to).to_h
        rebuilt = DiffAlgebra.apply(from&.to_h, diff)
        message = -> { "#{describe_case(label, from, to)}\ndiff: #{diff}" }

        expect(DiffAlgebra.normalize(rebuilt)).to eq(DiffAlgebra.normalize(to&.to_h)), message
      end
    end

    it 'reports the opposite change when compared the other way' do
      each_pair do |from, to, _generator, label|
        forward = compare(from, to).to_h
        message = -> { "#{describe_case(label, from, to)}\ndiff: #{forward}" }

        expect(compare(to, from).to_h).to eq(DiffAlgebra.invert(forward)), message
      end
    end

    it 'reports only real changes, in name and identity order' do
      each_pair do |from, to, _generator, label|
        diff = compare(from, to).to_h
        problems = DiffAlgebra::Problems.of(diff, from&.to_h, to&.to_h)

        expect(problems).to be_empty, -> { "#{describe_case(label, from, to)}\ndiff: #{diff}" }
      end
    end

    # Activity hands the engine a collection carried forward from the one
    # before with one record changed; reading the change from that must agree
    # with comparing the two collections whole.
    it 'reports the same change from a carried-forward collection as from one built apart' do
      each_pair do |from, to, generator, label|
        diff = compare(from, to).to_h

        expect(compare(from, generator.copy(to)).to_h).to eq(diff),
                                                          -> { describe_case(label, from, to) }
      end
    end

    it 'returns a diff no caller can change' do
      each_pair do |from, to, _generator, label|
        thawed = unfrozen(compare(from, to))

        expect(thawed).to be_empty, -> { "#{describe_case(label, from, to)}\nunfrozen: #{thawed}" }
      end
    end
  end

  # The paths to values in a diff, through its public readers, that are not
  # frozen.
  def unfrozen(value, path = 'diff')
    found = value.frozen? ? [] : [path]
    found + parts(value).flat_map { |name, item| unfrozen(item, "#{path}#{name}") }
  end

  # Each part of a value: a container's items, or what a result object's
  # readers return.
  def parts(value)
    case value
    when Hash then value.map { |key, item| ["[#{key.inspect}]", item] }
    when Array then value.each_with_index.map { |item, index| ["[#{index}]", item] }
    else readers(value).map { |name| [".#{name}", value.public_send(name)] }
    end
  end

  def readers(value)
    {
      PaperTrailDiff::Diff => %i[record_presence_change attributes associations],
      PaperTrailDiff::ValueChange => %i[from to],
      PaperTrailDiff::RecordChange => %i[record attributes associations],
      PaperTrailDiff::ToOneAssociationDiff => %i[relationship changed],
      PaperTrailDiff::CollectionAssociationDiff => %i[added removed changed],
      PaperTrailDiff::RecordSnapshot => %i[type id attributes associations],
      PaperTrailDiff::AssociationSnapshot => %i[records],
      PaperTrailDiff::RecordReference => %i[type id]
    }.find { |type, _names| value.is_a?(type) }&.last || []
  end
end
