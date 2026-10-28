# frozen_string_literal: true

# The pool hands back the snapshot it already holds when a new one at the same
# path says the same thing, so unchanged branches stay the same object and
# comparisons can skip them.
RSpec.describe PaperTrailDiff::SnapshotPool do
  subject(:pool) { described_class.new }

  def record(id = 1, type: 'Comment', body: 'same', associations: {})
    PaperTrailDiff::RecordSnapshot.new(
      type: type, id: id, attributes: { 'body' => body }, associations: associations
    )
  end

  def association(*records, kind: :has_many)
    PaperTrailDiff::AssociationSnapshot.new(kind: kind, records: records)
  end

  describe '#record' do
    it 'returns the held snapshot for an equivalent one at the same path' do
      tags = association(record(5, type: 'Tag'))
      first = pool.record('comments', record(associations: { 'tags' => tags }))

      expect(pool.record('comments', record(associations: { 'tags' => tags }))).to equal(first)
    end

    it 'keeps snapshots apart by path, type, and id' do
      first = pool.record('comments', record)

      expect(pool.record('notes', record)).not_to equal(first)
      expect(pool.record('comments', record(type: 'Note'))).not_to equal(first)
      expect(pool.record('comments', record(2))).not_to equal(first)
      expect(pool.record('comments', record)).to equal(first)
    end

    it 'replaces the held snapshot when its attributes change' do
      pool.record('comments', record)
      changed = record(body: 'new')

      expect(pool.record('comments', changed)).to equal(changed)
      expect(pool.record('comments', record(body: 'new'))).to equal(changed)
    end

    it 'replaces the held snapshot when its associations differ' do
      tags = association(record(5, type: 'Tag'))
      first = pool.record('comments', record(associations: { 'tags' => tags }))
      variants = [
        {},
        { 'tags' => tags, 'likes' => association },
        { 'likes' => tags },
        { 'tags' => association(record(5, type: 'Tag')) },
        { 'tags' => association(*tags.records, kind: :has_and_belongs_to_many) }
      ]

      variants.each do |associations|
        candidate = record(associations: associations)
        expect(pool.record('comments', candidate)).to equal(candidate)
        pool.record('comments', first)
      end
    end
  end

  describe '#association' do
    it 'returns the held association when kind and records match' do
      members = [record(1), record(2)]
      first = pool.association('comments', association(*members))

      expect(pool.association('comments', association(*members))).to equal(first)
      expect(pool.association('notes', association(*members))).not_to equal(first)
    end

    it 'replaces the held association when kind or records differ' do
      pool.association('comments', association(record(1)))
      other = association(record(1))
      habtm = association(*other.records, kind: :has_and_belongs_to_many)

      expect(pool.association('comments', other)).to equal(other)
      expect(pool.association('comments', habtm)).to equal(habtm)
      same_habtm = association(*habtm.records, kind: :has_and_belongs_to_many)

      expect(pool.association('comments', same_habtm)).to equal(habtm)
    end
  end
end
