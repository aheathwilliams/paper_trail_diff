# frozen_string_literal: true

require 'paper_trail_diff'

RSpec.describe PaperTrailDiff::ChangeRows do
  let(:source) do
    PaperTrailDiff::ActivityBoundary.new(
      kind: :version, version_id: 9, item_type: 'Article', item_id: 1,
      recorded_at: Time.utc(2026), event: 'update', whodunnit: 'alice', transaction_id: 4
    )
  end

  def record(type, id, attributes, **associations)
    PaperTrailDiff::RecordSnapshot.new(type: type, id: id, attributes: attributes,
                                       associations: associations)
  end

  def association(kind, *records)
    PaperTrailDiff::AssociationSnapshot.new(kind: kind, records: records)
  end

  def article(title, **associations)
    record('Article', 1, { 'title' => title }, **associations)
  end

  def rows(from, to)
    described_class.call(PaperTrailDiff::Engine.compare(from, to), source: source)
  end

  # Everything but the source, which every row shares.
  def table(from, to)
    rows(from, to).map do |row|
      [row.change, row.association_path, row.association_kind, row.record&.to_h,
       row.attribute, row.from, row.to]
    end
  end

  it 'gives an edited field one changed row, with nil for the root record' do
    expect(table(article('Draft'), article('Published')))
      .to eq([[:changed, [], nil, nil, 'title', 'Draft', 'Published']])
  end

  it 'gives a created root a row of its own, then one for each field that has a value' do
    created = record('Article', 1, { 'title' => 'New', 'summary' => nil })

    expect(table(nil, created)).to eq([[:added, [], nil, nil, nil, nil, nil],
                                       [:added, [], nil, nil, 'title', nil, 'New']])
    expect(table(created, nil)).to eq([[:removed, [], nil, nil, nil, nil, nil],
                                       [:removed, [], nil, nil, 'title', 'New', nil]])
  end

  it 'gives a record joining or leaving a collection a row, then rows for its fields' do
    comment = record('Comment', 7, { 'body' => 'Hi', 'note' => nil })
    empty = article('Same', comments: association(:has_many))
    with = article('Same', comments: association(:has_many, comment))
    ref = { type: 'Comment', id: 7 }

    expect(table(empty, with))
      .to eq([[:added, ['comments'], :has_many, ref, nil, nil, nil],
              [:added, ['comments'], :has_many, ref, 'body', nil, 'Hi']])
    expect(table(with, empty))
      .to eq([[:removed, ['comments'], :has_many, ref, nil, nil, nil],
              [:removed, ['comments'], :has_many, ref, 'body', 'Hi', nil]])
  end

  it "names an edited child's field without a row for the child itself" do
    edited = ->(body) { record('Comment', 7, { 'body' => body }) }
    before = article('Same', comments: association(:has_many, edited.call('a')))
    after = article('Same', comments: association(:has_many, edited.call('b')))

    expect(table(before, after))
      .to eq([[:changed, ['comments'], :has_many, { type: 'Comment', id: 7 }, 'body', 'a', 'b']])
  end

  it 'gives a replaced to-one target a removed row, then an added one' do
    alice = record('Author', 1, { 'name' => 'Alice' })
    bob = record('Author', 2, { 'name' => 'Bob' })

    expect(table(article('Same', author: association(:belongs_to, alice)),
                 article('Same', author: association(:belongs_to, bob))))
      .to eq([[:removed, ['author'], :belongs_to, { type: 'Author', id: 1 }, nil, nil, nil],
              [:removed, ['author'], :belongs_to, { type: 'Author', id: 1 }, 'name', 'Alice', nil],
              [:added, ['author'], :belongs_to, { type: 'Author', id: 2 }, nil, nil, nil],
              [:added, ['author'], :belongs_to, { type: 'Author', id: 2 }, 'name', nil, 'Bob']])
  end

  it 'lists the records an added record holds, at their own path' do
    reply = record('Reply', 3, { 'text' => 'Yes' })
    comment = record('Comment', 7, { 'body' => 'Hi' }, replies: association(:has_many, reply))

    expect(table(article('Same', comments: association(:has_many)),
                 article('Same', comments: association(:has_many, comment))))
      .to eq([[:added, ['comments'], :has_many, { type: 'Comment', id: 7 }, nil, nil, nil],
              [:added, ['comments'], :has_many, { type: 'Comment', id: 7 }, 'body', nil, 'Hi'],
              [:added, %w[comments replies], :has_many, { type: 'Reply', id: 3 }, nil, nil, nil],
              [:added, %w[comments replies], :has_many, { type: 'Reply', id: 3 }, 'text', nil,
               'Yes']])
  end

  it 'keeps a field changed to or from nil' do
    expect(table(record('Article', 1, { 'title' => nil }), article('Set')))
      .to eq([[:changed, [], nil, nil, 'title', nil, 'Set']])
  end

  it 'returns no rows for no change, frozen' do
    result = rows(article('Same'), article('Same'))

    expect(result).to eq([])
    expect(result).to be_frozen
  end

  it 'attributes every row to the source, and flattens it into the hash' do
    row = rows(article('Draft'), article('Published')).first

    expect(row.source).to equal(source)
    expect(row).to be_frozen
    expect(row.to_h).to eq(
      change: :changed, association_path: [], association_kind: nil, record: nil,
      attribute: 'title', from: 'Draft', to: 'Published', version_id: 9, event: 'update',
      whodunnit: 'alice', recorded_at: Time.utc(2026), transaction_id: 4
    )
  end

  it 'gives plain, unfrozen copies of stored values in the hash, from either side' do
    comment = record('Comment', 7, { 'meta' => { 'tags' => %w[a b] } })
    empty = article('Same', comments: association(:has_many))
    with = article('Same', comments: association(:has_many, comment))
    added = rows(empty, with).last
    removed = rows(with, empty).last

    expect(added.to_h).to include(record: { type: 'Comment', id: 7 }, association_kind: :has_many,
                                  from: nil, to: { 'tags' => %w[a b] })
    expect(removed.to_h).to include(from: { 'tags' => %w[a b] }, to: nil)
    expect(added.to).to be_frozen
    expect(added.to_h.fetch(:to)).not_to be_frozen
    expect(removed.to_h.fetch(:from)).not_to be_frozen
  end
end
