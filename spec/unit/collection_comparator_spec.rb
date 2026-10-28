# frozen_string_literal: true

RSpec.describe PaperTrailDiff::CollectionComparator do
  def record(id, body = 'same', type: 'Comment')
    PaperTrailDiff::RecordSnapshot.new(type: type, id: id, attributes: { 'body' => body })
  end

  def association(*records)
    PaperTrailDiff::AssociationSnapshot.new(kind: :has_many, records: records)
  end

  # Records each pair it is asked about and reports "id: body" for a change.
  let(:compared) { [] }
  let(:record_comparer) do
    lambda do |from, to|
      compared << [from.id, to.id]
      "#{to.id}: #{to.attributes.fetch('body')}" unless from.attributes == to.attributes
    end
  end

  def compare(from, to)
    described_class.new(from, to, record_comparer: record_comparer).call
  end

  def ids(records)
    records.map(&:id)
  end

  describe 'records in the same order on both sides' do
    it 'reports changes in identity order, not position' do
      diff = compare(association(record(10), record(3)),
                     association(record(10, 'new'), record(3, 'new')))

      expect(diff.changed).to eq(['3: new', '10: new'])
      expect(diff.added).to be_empty
      expect(diff.removed).to be_empty
      expect(diff.kind).to eq(:has_many)
    end

    it 'orders changes by type first, then naturally within mixed id types' do
      from = association(record(1, type: 'Video'), record('a'), record(2))
      to = association(record(1, 'new', type: 'Video'), record('a', 'new'), record(2, 'new'))

      expect(compare(from, to).changed).to eq(['2: new', 'a: new', '1: new'])
    end

    it 'compares only records that are not shared, and keeps only real changes' do
      shared = record(1)

      diff = compare(association(shared, record(2), record(3)),
                     association(shared, record(2, 'new'), record(3)))

      expect(diff.changed).to eq(['2: new'])
      expect(compared).to eq([[2, 2], [3, 3]])
    end

    # The shortcut exists for speed: stable membership is the common case.
    it 'compares them without indexing either side' do
      comparator = described_class.new(
        association(record(1), record(2)), association(record(1), record(2, 'new')),
        record_comparer: record_comparer
      )
      allow(comparator).to receive(:index_records).and_call_original

      comparator.call

      expect(comparator).not_to have_received(:index_records)
    end

    it 'rejects a duplicated identity' do
      from = association(record(1), record(1, 'twin'))
      to = association(record(1), record(1, 'twin'))

      expect { compare(from, to) }
        .to raise_error(ArgumentError, 'duplicate record identity: ["Comment", 1]')
    end
  end

  describe 'membership or order that differs' do
    it 'reports records added at the end' do
      diff = compare(association(record(1)), association(record(1), record(2)))

      expect(ids(diff.added)).to eq([2])
      expect(diff.removed).to be_empty
    end

    it 'reports records removed from the end' do
      diff = compare(association(record(1), record(2)), association(record(1)))

      expect(ids(diff.removed)).to eq([2])
      expect(diff.added).to be_empty
    end

    it 'matches reordered records by identity, not position' do
      diff = compare(association(record(1, 'one'), record(2, 'two')),
                     association(record(2, 'two'), record(1, 'one')))

      expect(diff).to be_empty
    end

    it 'reports changes to reordered records in identity order' do
      diff = compare(association(record(10), record(3)),
                     association(record(3, 'new'), record(10, 'new')))

      expect(diff.changed).to eq(['3: new', '10: new'])
      expect(diff.added).to be_empty
      expect(diff.removed).to be_empty
    end

    it 'compares only records that are not shared' do
      shared = record(1)

      diff = compare(association(shared, record(2)),
                     association(record(2, 'new'), shared, record(3)))

      expect(diff.changed).to eq(['2: new'])
      expect(ids(diff.added)).to eq([3])
      expect(compared).to eq([[2, 2]])
    end

    it 'orders numbers, then text, then other ids by their printed form' do
      records = [[1, 2], :c, 10, 'd', 'b', [1, 10], :a, 2].map { |id| record(id) }

      diff = compare(association, association(*records))

      expect(ids(diff.added)).to eq([2, 10, :a, 'b', :c, 'd', [1, 10], [1, 2]])
    end

    it 'orders by type before id' do
      diff = compare(association, association(record(1, type: 'Video'), record(2, type: 'Article')))

      expect(diff.added.map(&:type)).to eq(%w[Article Video])
    end

    it 'rejects a duplicated identity' do
      from = association(record(1), record(1, 'twin'))

      expect { compare(from, association(record(2))) }
        .to raise_error(ArgumentError, 'duplicate record identity: ["Comment", 1]')
    end
  end

  describe 'a transition carried from the previous snapshot' do
    def transition(from, records, before:, after:)
      from.transition_to(records, before: before, after: after, membership_preserved: false)
    end

    it 'reports an update to the named record' do
      before = record(1)
      after = record(1, 'new')
      from = association(before, record(2))

      diff = compare(from, transition(from, [after, record(2)], before: before, after: after))

      expect(diff.changed).to eq(['1: new'])
      expect(compared).to eq([[1, 1]])
    end

    it 'reports nothing when the named record did not change' do
      before = record(1)
      from = association(before)

      diff = compare(from, transition(from, [record(1)], before: before, after: record(1)))

      expect(diff).to be_empty
    end

    it 'reports an addition and a removal' do
      kept = record(1)
      joined = record(2)
      empty = association(kept)
      added = transition(empty, [kept, joined], before: nil, after: joined)
      removed = transition(added, [kept], before: joined, after: nil)

      joined_diff = compare(empty, added).to_h
      left_diff = compare(added, removed).to_h

      expect(joined_diff).to include(added: [joined.to_h], removed: [], changed: [])
      expect(left_diff).to include(added: [], removed: [joined.to_h], changed: [])
    end

    it 'reports a replacement by another record as a removal and an addition' do
      before = record(1)
      after = record(2)
      from = association(before)

      diff = compare(from, transition(from, [after], before: before, after: after))

      expect(ids(diff.removed)).to eq([1])
      expect(ids(diff.added)).to eq([2])
      expect(diff.changed).to be_empty
      expect(compared).to be_empty
    end

    it 'rejects a duplicated identity on either side' do
      twin = record(1, 'twin')
      from = association(record(1), twin)
      to = transition(from, [record(1)], before: twin, after: nil)
      clean = association(record(1))
      extra = record(1, 'x')
      duplicated = transition(clean, [record(1), extra], before: nil, after: extra)

      expect { compare(from, to) }.to raise_error(ArgumentError, /duplicate record identity/)
      expect do
        compare(clean, duplicated)
      end.to raise_error(ArgumentError, /duplicate record identity/)
    end
  end
end
