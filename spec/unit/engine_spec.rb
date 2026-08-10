# frozen_string_literal: true

RSpec.describe PaperTrailDiff::Engine do
  def snapshot(type:, id:, attributes:, associations: {})
    PaperTrailDiff::RecordSnapshot.new(
      type: type,
      id: id,
      attributes: attributes,
      associations: associations
    )
  end

  def association(kind, *records)
    PaperTrailDiff::AssociationSnapshot.new(kind: kind, records: records)
  end

  it 'validates association snapshot kinds and singular cardinality' do
    record = snapshot(type: 'Author', id: 1, attributes: {})

    expect { association(:unsupported, record) }
      .to raise_error(ArgumentError, /unsupported association kind/)
    expect { association(:belongs_to, record, record) }
      .to raise_error(ArgumentError, /at most one record/)
  end

  it 'reuses frozen record arrays while isolating mutable caller input' do
    record = snapshot(type: 'Author', id: 1, attributes: {})
    frozen_records = [record].freeze
    mutable_records = [record]

    expect(PaperTrailDiff::AssociationSnapshot.new(
      kind: :has_many, records: frozen_records
    ).records).to equal(frozen_records)
    expect(PaperTrailDiff::AssociationSnapshot.new(
      kind: :has_many, records: mutable_records
    ).records).not_to equal(mutable_records)
  end

  it 'returns sorted scalar attribute changes' do
    from = snapshot(type: 'Article', id: 1, attributes: { zeta: 1, alpha: 'old' })
    to = snapshot(type: 'Article', id: 1, attributes: { zeta: 2, alpha: 'new' })

    result = described_class.compare(from, to)

    expect(result.to_h).to eq(
      record_presence_change: nil,
      attributes: {
        'alpha' => { from: 'old', to: 'new' },
        'zeta' => { from: 1, to: 2 }
      },
      associations: {}
    )
    expect(result).not_to be_empty
  end

  it 'returns an empty diff for equal snapshots' do
    from = snapshot(type: 'Article', id: 1, attributes: { title: 'Same' })
    to = snapshot(type: 'Article', id: 1, attributes: { title: 'Same' })

    expect(described_class.compare(from, to)).to be_empty
  end

  it 'returns an empty diff for independently normalized equal collections' do
    from_child = snapshot(type: 'Comment', id: 1, attributes: { body: 'Same' })
    to_child = snapshot(type: 'Comment', id: 1, attributes: { body: 'Same' })
    from = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { comments: association(:has_many, from_child) }
    )
    to = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { comments: association(:has_many, to_child) }
    )

    expect(described_class.compare(from, to)).to be_empty
  end

  it 'represents a missing endpoint as a root record presence change' do
    record = snapshot(type: 'Article', id: 1, attributes: { title: 'Created' })

    result = described_class.compare(nil, record)

    expect(result.to_h).to eq(
      record_presence_change: {
        from: nil,
        to: { type: 'Article', id: 1, attributes: { 'title' => 'Created' } }
      },
      attributes: {},
      associations: {}
    )
    expect(described_class.compare(nil, nil)).to be_empty
  end

  it 'keeps singular relationship replacement separate from record attributes' do
    old_author = snapshot(type: 'Author', id: 1, attributes: { name: 'Ada' })
    new_author = snapshot(type: 'Author', id: 2, attributes: { name: 'Grace' })
    from = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { author: association(:belongs_to, old_author) }
    )
    to = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { author: association(:belongs_to, new_author) }
    )

    author_diff = described_class.compare(from, to).associations.fetch('author')

    expect(author_diff.to_h).to eq(
      kind: :belongs_to,
      relationship: {
        from: { type: 'Author', id: 1, attributes: { 'name' => 'Ada' } },
        to: { type: 'Author', id: 2, attributes: { 'name' => 'Grace' } }
      },
      changed: nil
    )
  end

  it 'reports scalar changes for a singular association with the same identity' do
    old_profile = snapshot(type: 'Profile', id: 4, attributes: { bio: 'Before' })
    new_profile = snapshot(type: 'Profile', id: 4, attributes: { bio: 'After' })
    from = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { profile: association(:has_one, old_profile) }
    )
    to = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { profile: association(:has_one, new_profile) }
    )

    profile_diff = described_class.compare(from, to).associations.fetch('profile')

    expect(profile_diff.to_h).to eq(
      kind: :has_one,
      relationship: nil,
      changed: {
        record: { type: 'Profile', id: 4 },
        attributes: { 'bio' => { from: 'Before', to: 'After' } }
      }
    )
    expect(profile_diff.changed.record).to be_a(PaperTrailDiff::RecordReference)
    expect(profile_diff.changed.record.id).to eq(4)
    expect(profile_diff.changed.record[:type]).to eq('Profile')
    expect(profile_diff.changed.record.fetch('id')).to eq(4)
    expect(profile_diff.changed.record).to be_frozen
  end

  it 'raises when a record reference is fetched with an unknown key' do
    reference = PaperTrailDiff::RecordReference.new(type: 'Article', id: 1)

    expect(reference[:missing]).to be_nil
    expect { reference.fetch(:missing) }.to raise_error(KeyError, /missing/)
  end

  it 'reports collection additions, removals, and updates in identity order' do
    removed = snapshot(type: 'Comment', id: 1, attributes: { body: 'Removed' })
    before = snapshot(type: 'Comment', id: 2, attributes: { body: 'Before' })
    after = snapshot(type: 'Comment', id: 2, attributes: { body: 'After' })
    added_ten = snapshot(type: 'Comment', id: 10, attributes: { body: 'Ten' })
    added_three = snapshot(type: 'Comment', id: 3, attributes: { body: 'Three' })
    from = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { comments: association(:has_many, before, removed) }
    )
    to = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { comments: association(:has_many, added_three, after, added_ten) }
    )

    comments = described_class.compare(from, to).associations.fetch('comments')

    expect(comments.added.map(&:id)).to eq([10, 3])
    expect(comments.removed.map(&:id)).to eq([1])
    expect(comments.changed.map(&:to_h)).to eq(
      [{
        record: { type: 'Comment', id: 2 },
        attributes: { 'body' => { from: 'Before', to: 'After' } }
      }]
    )
  end

  it 'reports aligned collection changes in deterministic identity order' do
    before_three = snapshot(type: 'Comment', id: 3, attributes: { body: 'Before 3' })
    after_three = snapshot(type: 'Comment', id: 3, attributes: { body: 'After 3' })
    before_ten = snapshot(type: 'Comment', id: 10, attributes: { body: 'Before 10' })
    after_ten = snapshot(type: 'Comment', id: 10, attributes: { body: 'After 10' })
    from = snapshot(
      type: 'Article', id: 1, attributes: {},
      associations: { comments: association(:has_many, before_three, before_ten) }
    )
    to = snapshot(
      type: 'Article', id: 1, attributes: {},
      associations: { comments: association(:has_many, after_three, after_ten) }
    )
    changed = described_class.compare(from, to).associations.fetch('comments').changed

    expect(changed.map { |change| change.record.id }).to eq([10, 3])
  end

  it 'reports updates from an adjacent collection transition' do
    before = snapshot(type: 'Comment', id: 2, attributes: { body: 'Before' })
    after = snapshot(type: 'Comment', id: 2, attributes: { body: 'After' })
    from_association = association(:has_many, before)
    to_association = from_association.transition_to(
      [after],
      before: before,
      after: after,
      membership_preserved: true
    )
    from = snapshot(
      type: 'Article', id: 1, attributes: {},
      associations: { comments: from_association }
    )
    to = snapshot(
      type: 'Article', id: 1, attributes: {},
      associations: { comments: to_association }
    )

    change = described_class.compare(from, to).associations.fetch('comments').changed.fetch(0)

    expect(change.attributes.fetch('body').to_h).to eq(from: 'Before', to: 'After')
  end

  it 'applies a collection transition only to the snapshot it was carried from' do
    before = snapshot(type: 'Comment', id: 2, attributes: { body: 'Before' })
    after = snapshot(type: 'Comment', id: 2, attributes: { body: 'After' })
    from_association = association(:has_many, before)
    equivalent = association(:has_many, before)
    to_association = from_association.transition_to(
      [after],
      before: before,
      after: after,
      membership_preserved: true
    )

    expect(to_association.transition_from(from_association)).not_to be_nil
    # Same kind and same records, but not the snapshot the transition recorded.
    expect(to_association.transition_from(equivalent)).to be_nil
    expect(from_association.serial).not_to eq(equivalent.serial)
  end

  it 'reports additions and removals from adjacent collection transitions' do
    existing = snapshot(type: 'Comment', id: 1, attributes: {})
    transient = snapshot(type: 'Comment', id: 2, attributes: {})
    before_add = association(:has_many, existing)
    after_add = before_add.transition_to(
      [existing, transient],
      before: nil,
      after: transient,
      membership_preserved: false
    )
    after_remove = after_add.transition_to(
      [existing],
      before: transient,
      after: nil,
      membership_preserved: false
    )

    added = PaperTrailDiff::CollectionComparator.new(
      before_add, after_add, record_comparer: ->(*) {}
    ).call
    removed = PaperTrailDiff::CollectionComparator.new(
      after_add, after_remove, record_comparer: ->(*) {}
    ).call

    expect(added.added.map(&:id)).to eq([2])
    expect(removed.removed.map(&:id)).to eq([2])
  end

  it 'does not rescan stable members in an indexed adjacent transition' do
    identity_reads = [0]
    counting_snapshot = Class.new(PaperTrailDiff::RecordSnapshot) do
      define_method(:identity) do
        identity_reads[0] += 1
        super()
      end
    end
    records = 100.times.map do |id|
      counting_snapshot.new(type: 'Comment', id: id, attributes: {})
    end
    before = records.fetch(50)
    after = snapshot(type: 'Comment', id: 50, attributes: { body: 'After' })
    from_association = association(:has_many, *records)
    serialized = from_association.to_h
    from_association.position('Comment', 50)
    expect(from_association.to_h).to eq(serialized)
    expect(from_association).to be_frozen
    identity_reads[0] = 0
    updated = records.dup
    updated[50] = after
    to_association = from_association.transition_to(
      updated,
      before: before,
      after: after,
      membership_preserved: true
    )

    PaperTrailDiff::CollectionComparator.new(
      from_association, to_association, record_comparer: ->(*) {}
    ).call

    expect(identity_reads.fetch(0)).to eq(1)
  end

  it 'treats HABTM as a collection while preserving its macro kind' do
    removed = snapshot(type: 'Tag', id: 1, attributes: { name: 'Removed' })
    before = snapshot(type: 'Tag', id: 2, attributes: { name: 'Before' })
    after = snapshot(type: 'Tag', id: 2, attributes: { name: 'After' })
    added = snapshot(type: 'Tag', id: 3, attributes: { name: 'Added' })
    from = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { tags: association(:has_and_belongs_to_many, removed, before) }
    )
    to = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { tags: association(:has_and_belongs_to_many, after, added) }
    )

    tags = described_class.compare(from, to).associations.fetch('tags')

    expect(tags.kind).to eq(:has_and_belongs_to_many)
    expect(tags.added.map(&:id)).to eq([3])
    expect(tags.removed.map(&:id)).to eq([1])
    expect(tags.changed.fetch(0).attributes.fetch('name').to_h)
      .to eq(from: 'Before', to: 'After')
  end

  it 'rejects an association macro that changes between snapshots' do
    child = snapshot(type: 'Comment', id: 1, attributes: {})
    from = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { comments: association(:has_many, child) }
    )
    to = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { comments: association(:has_one, child) }
    )

    expect { described_class.compare(from, to) }
      .to raise_error(ArgumentError, /association kind changed/)
  end

  it 'reports nested association changes for stable parent identities' do
    old_reply = snapshot(type: 'Reply', id: 9, attributes: { body: 'Before' })
    new_reply = snapshot(type: 'Reply', id: 9, attributes: { body: 'After' })
    old_comment = snapshot(
      type: 'Comment',
      id: 2,
      attributes: { body: 'Parent' },
      associations: { replies: association(:has_many, old_reply) }
    )
    new_comment = snapshot(
      type: 'Comment',
      id: 2,
      attributes: { body: 'Parent' },
      associations: { replies: association(:has_many, new_reply) }
    )
    from = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { comments: association(:has_many, old_comment) }
    )
    to = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { comments: association(:has_many, new_comment) }
    )

    result = described_class.compare(from, to).to_h

    expect(result.dig(:associations, 'comments', :changed, 0, :associations, 'replies'))
      .to eq(
        kind: :has_many,
        added: [],
        removed: [],
        changed: [{
          record: { type: 'Reply', id: 9 },
          attributes: { 'body' => { from: 'Before', to: 'After' } }
        }]
      )
  end

  it 'serializes selected subtrees on added and removed records' do
    reply = snapshot(type: 'Reply', id: 9, attributes: { body: 'Nested' })
    comment = snapshot(
      type: 'Comment',
      id: 2,
      attributes: { body: 'Parent' },
      associations: { replies: association(:has_many, reply) }
    )
    from = snapshot(type: 'Article', id: 1, attributes: {})
    to = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { comments: association(:has_many, comment) }
    )

    added = described_class.compare(from, to).to_h.dig(
      :associations,
      'comments',
      :added,
      0
    )

    expect(added[:associations]).to eq(
      'replies' => {
        kind: :has_many,
        records: [{ type: 'Reply', id: 9, attributes: { 'body' => 'Nested' } }]
      }
    )
  end

  it 'rejects duplicate collection identities' do
    duplicate = snapshot(type: 'Comment', id: 1, attributes: {})
    from = snapshot(
      type: 'Article',
      id: 1,
      attributes: {},
      associations: { comments: association(:has_many, duplicate, duplicate) }
    )
    to = snapshot(type: 'Article', id: 1, attributes: {})

    expect { described_class.compare(from, to) }
      .to raise_error(ArgumentError, /duplicate record identity/)
  end

  it 'rejects aligned duplicate collection identities on the fast path' do
    duplicate = snapshot(type: 'Comment', id: 1, attributes: {})
    from = snapshot(
      type: 'Article', id: 1, attributes: {},
      associations: { comments: association(:has_many, duplicate, duplicate) }
    )
    to = snapshot(
      type: 'Article', id: 1, attributes: {},
      associations: { comments: association(:has_many, duplicate, duplicate) }
    )

    expect { described_class.compare(from, to) }
      .to raise_error(ArgumentError, /duplicate record identity/)
  end

  it 'rejects duplicate identities in an adjacent collection transition' do
    duplicate = snapshot(type: 'Comment', id: 1, attributes: {})
    from_association = association(:has_many, duplicate)
    to_association = from_association.transition_to(
      [duplicate, duplicate],
      before: nil,
      after: duplicate,
      membership_preserved: false
    )
    from = snapshot(
      type: 'Article', id: 1, attributes: {},
      associations: { comments: from_association }
    )
    to = snapshot(
      type: 'Article', id: 1, attributes: {},
      associations: { comments: to_association }
    )

    expect { described_class.compare(from, to) }
      .to raise_error(ArgumentError, /duplicate record identity/)
  end

  it 'isolates and freezes source containers and strings' do
    source = { title: +'Mutable', metadata: { tags: [+'one'] } }
    record = snapshot(type: 'Article', id: 1, attributes: source)
    source[:title] << ' changed'
    source[:metadata][:tags] << 'two'

    expect(record.attributes).to eq(
      'metadata' => { tags: ['one'] },
      'title' => 'Mutable'
    )
    expect { record.attributes['title'] << '!' }.to raise_error(FrozenError)
    expect { record.attributes['new'] = true }.to raise_error(FrozenError)
  end
end
