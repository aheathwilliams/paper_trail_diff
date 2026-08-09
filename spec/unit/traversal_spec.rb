# frozen_string_literal: true

RSpec.describe 'diff traversal' do
  def snapshot(type:, id:, attributes: {}, associations: {})
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

  def entry_summary(entry)
    {
      kind: entry.kind,
      context: entry.context,
      associations: entry.association_path,
      records: entry.record_path.map(&:to_h),
      association_kind: entry.association_kind,
      state: entry.state,
      attribute: entry.attribute
    }
  end

  it 'enumerates root and deeply nested semantic changes in deterministic depth-first order' do
    old_reply = snapshot(type: 'Reply', id: 9, attributes: { body: 'Before' })
    new_reply = snapshot(type: 'Reply', id: 9, attributes: { body: 'After' })
    old_comment = snapshot(
      type: 'Comment',
      id: 2,
      attributes: { body: 'Old' },
      associations: { replies: association(:has_many, old_reply) }
    )
    new_comment = snapshot(
      type: 'Comment',
      id: 2,
      attributes: { body: 'New' },
      associations: { replies: association(:has_many, new_reply) }
    )
    from = snapshot(
      type: 'Article',
      id: 1,
      attributes: { title: 'Draft' },
      associations: { comments: association(:has_many, old_comment) }
    )
    to = snapshot(
      type: 'Article',
      id: 1,
      attributes: { title: 'Published' },
      associations: { comments: association(:has_many, new_comment) }
    )

    entries = PaperTrailDiff::Engine.compare(from, to).each_change.to_a

    expect(entries.map { |entry| entry_summary(entry) }).to eq(
      [
        {
          kind: :attribute_changed, context: :change, associations: [], records: [],
          association_kind: nil, state: nil, attribute: 'title'
        },
        {
          kind: :record_changed, context: :change, associations: ['comments'],
          records: [{ type: 'Comment', id: 2 }], association_kind: :has_many,
          state: nil, attribute: nil
        },
        {
          kind: :attribute_changed, context: :change, associations: ['comments'],
          records: [{ type: 'Comment', id: 2 }], association_kind: :has_many,
          state: nil, attribute: 'body'
        },
        {
          kind: :record_changed, context: :change,
          associations: %w[comments replies],
          records: [{ type: 'Comment', id: 2 }, { type: 'Reply', id: 9 }],
          association_kind: :has_many, state: nil, attribute: nil
        },
        {
          kind: :attribute_changed, context: :change,
          associations: %w[comments replies],
          records: [{ type: 'Comment', id: 2 }, { type: 'Reply', id: 9 }],
          association_kind: :has_many, state: nil, attribute: 'body'
        }
      ]
    )
    expect(entries.first.value.to_h).to eq(from: 'Draft', to: 'Published')
    expect(entries.fetch(1).record.to_h).to eq(type: 'Comment', id: 2)
    expect(entries.fetch(1).association).to eq('comments')
    expect(entries).to all(be_frozen)
  end

  it 'walks nested state carried by collection additions and removals ' \
     'without treating it as change' do
    reply = snapshot(type: 'Reply', id: 7, attributes: { body: 'Included' })
    added = snapshot(
      type: 'Comment',
      id: 3,
      attributes: { body: 'Added' },
      associations: {
        replies: association(:has_many, reply),
        tags: association(:has_many)
      }
    )
    removed = snapshot(type: 'Comment', id: 1, attributes: { body: 'Removed' })
    from = snapshot(
      type: 'Article', id: 1,
      associations: { comments: association(:has_many, removed) }
    )
    to = snapshot(
      type: 'Article', id: 1,
      associations: { comments: association(:has_many, added) }
    )

    diff = PaperTrailDiff::Engine.compare(from, to)
    entries = diff.each_entry.to_a

    expect(diff.each_change.map(&:kind)).to eq(%i[record_added record_removed])
    expect(entries.map(&:kind)).to eq(
      %i[
        record_added attribute_included association_included record_included
        attribute_included association_included record_removed attribute_included
      ]
    )
    nested_reply = entries.find do |entry|
      entry.kind == :record_included && entry.record&.type == 'Reply'
    end
    expect(entry_summary(nested_reply)).to eq(
      kind: :record_included,
      context: :included_state,
      associations: %w[comments replies],
      records: [{ type: 'Comment', id: 3 }, { type: 'Reply', id: 7 }],
      association_kind: :has_many,
      state: :after,
      attribute: nil
    )
    empty_association = entries.find do |entry|
      entry.kind == :association_included && entry.association == 'tags'
    end
    expect(empty_association.value.records).to eq([])
    expect(empty_association).to be_included_state
    yielded_entries = []
    yielded_changes = []
    expect(diff.each_entry { |entry| yielded_entries << entry }).to equal(diff)
    expect(diff.each_change { |entry| yielded_changes << entry }).to equal(diff)
    expect(yielded_entries.map(&:to_h)).to eq(entries.map(&:to_h))
    expect(yielded_changes.map(&:to_h)).to eq(diff.each_change.map(&:to_h))
  end

  it 'classifies singular relationship additions, removals, and replacements' do
    author_one = snapshot(type: 'Author', id: 1, attributes: { name: 'Ada' })
    author_two = snapshot(type: 'Author', id: 2, attributes: { name: 'Grace' })
    empty = snapshot(type: 'Article', id: 1)
    with_one = snapshot(
      type: 'Article', id: 1,
      associations: { author: association(:belongs_to, author_one) }
    )
    with_two = snapshot(
      type: 'Article', id: 1,
      associations: { author: association(:belongs_to, author_two) }
    )

    added = PaperTrailDiff::Engine.compare(empty, with_one).each_entry.to_a
    removed = PaperTrailDiff::Engine.compare(with_one, empty).each_entry.to_a
    replaced = PaperTrailDiff::Engine.compare(with_one, with_two).each_entry.to_a

    expect(added.map(&:kind)).to eq(
      %i[relationship_added record_included attribute_included]
    )
    expect(removed.map(&:kind)).to eq(
      %i[relationship_removed record_included attribute_included]
    )
    expect(replaced.map(&:kind)).to eq(
      %i[
        relationship_replaced record_included attribute_included
        record_included attribute_included
      ]
    )
    expect(added.map(&:state)).to eq([nil, :after, :after])
    expect(removed.map(&:state)).to eq([nil, :before, :before])
    expect(replaced.select { |entry| entry.kind == :record_included }.map(&:state))
      .to eq(%i[before after])
    expect(replaced.first).to be_change
    expect(replaced.first.association_kind).to eq(:belongs_to)
  end

  it 'walks both sides of a root presence change with an empty root record path' do
    comment = snapshot(type: 'Comment', id: 2, attributes: { body: 'Present' })
    article = snapshot(
      type: 'Article', id: 1, attributes: { title: 'Created' },
      associations: { comments: association(:has_many, comment) }
    )

    created = PaperTrailDiff::Engine.compare(nil, article).each_entry.to_a
    destroyed = PaperTrailDiff::Engine.compare(article, nil).each_entry.to_a

    expect(created.map(&:kind)).to eq(
      %i[
        record_presence_changed record_included attribute_included
        association_included record_included attribute_included
      ]
    )
    expect(created.map(&:state).compact).to all(eq(:after))
    expect(destroyed.map(&:state).compact).to all(eq(:before))
    expect(created.first.value.to_h[:to]).to include(type: 'Article', id: 1)
    expect(created.fetch(1).record_path).to eq([])
    expect(created.fetch(4).record_path.map(&:type)).to eq(['Comment'])
  end

  it 'serializes immutable entries and rejects invalid traversal metadata' do
    from = snapshot(type: 'Article', id: 1, attributes: { title: 'Before' })
    to = snapshot(type: 'Article', id: 1, attributes: { title: 'After' })
    entry = PaperTrailDiff::Engine.compare(from, to).each_entry.first

    expect(entry.to_h).to eq(
      kind: :attribute_changed,
      context: :change,
      association_path: [],
      record_path: [],
      association_kind: nil,
      state: nil,
      attribute: 'title',
      value: { from: 'Before', to: 'After' }
    )
    expect(entry.association_path).to be_frozen
    expect(entry.record_path).to be_frozen
    expect { entry.association_path << 'comments' }.to raise_error(FrozenError)

    base = {
      kind: :attribute_changed,
      association_path: [],
      record_path: [],
      association_kind: nil,
      attribute: nil,
      value: nil
    }
    expect do
      PaperTrailDiff::TraversalEntry.new(**base, context: :invalid, state: nil)
    end.to raise_error(ArgumentError, /context/)
    expect do
      PaperTrailDiff::TraversalEntry.new(**base, context: :change, state: :invalid)
    end.to raise_error(ArgumentError, /state/)
  end
end
