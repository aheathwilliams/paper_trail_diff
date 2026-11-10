# frozen_string_literal: true

RSpec.describe PaperTrailDiff::SnapshotMembers do
  subject(:members) { described_class.new }

  def record(type, id, **associations)
    PaperTrailDiff::RecordSnapshot.new(type: type, id: id, attributes: {},
                                       associations: associations)
  end

  def collection(*records)
    PaperTrailDiff::AssociationSnapshot.new(kind: :has_many, records: records)
  end

  def root(**associations)
    record('Article', 1, **associations)
  end

  # Whether the snapshot holds each of the comments and replies 1 to 4.
  def held(snapshot, branches = ['comments'])
    members.move_to(snapshot)
    %w[Comment Reply].to_h do |type|
      [type, (1..4).select { |id| members.holds?(branches, [type], id) }]
    end
  end

  it 'holds the records under a branch at any depth' do
    replied = record('Comment', 1, replies: collection(record('Reply', 3)))
    snapshot = root(comments: collection(replied, record('Comment', 2)))

    expect(held(snapshot)).to eq('Comment' => [1, 2], 'Reply' => [3])
  end

  it 'holds a record only under the branches asked about' do
    snapshot = root(comments: collection(record('Comment', 1)),
                    notes: collection(record('Reply', 2)))

    expect(held(snapshot)).to eq('Comment' => [1], 'Reply' => [])
    expect(held(snapshot, %w[comments notes])).to eq('Comment' => [1], 'Reply' => [2])
    expect(held(snapshot, ['other'])).to eq('Comment' => [], 'Reply' => [])
  end

  it 'finds a record under any of the types given, by the text of its id' do
    members.move_to(root(comments: collection(record('Comment', 1), record('Comment', 'b'))))

    expect(members.holds?(['comments'], %w[Note Comment], '1')).to be(true)
    expect(members.holds?(['comments'], ['Comment'], :b)).to be(true)
    expect(members.holds?(['comments'], ['Note'], 1)).to be(false)
  end

  it 'holds nothing before a snapshot, or at none' do
    expect(members.holds?(['comments'], ['Comment'], 1)).to be(false)

    members.move_to(root(comments: collection(record('Comment', 1))))
    expect(held(nil)).to eq('Comment' => [], 'Reply' => [])
  end

  it 'follows a collection through the record each transition changed' do
    first = collection(record('Comment', 1, replies: collection(record('Reply', 1))),
                       record('Comment', 3))
    added = record('Comment', 2)
    second = first.transition_to([first.records.first, added, first.records.last],
                                 before: nil, after: added)
    third = second.transition_to(second.records.first(2), before: second.records.last, after: nil)

    expect(held(root(comments: first))).to eq('Comment' => [1, 3], 'Reply' => [1])
    expect(held(root(comments: second))).to eq('Comment' => [1, 2, 3], 'Reply' => [1])
    expect(held(root(comments: third))).to eq('Comment' => [1, 2], 'Reply' => [1])
  end

  it 'follows a record that changed into the collections it holds' do
    replies = collection(record('Reply', 1))
    more = replies.transition_to([replies.records.first, record('Reply', 2)],
                                 before: nil, after: record('Reply', 2))
    before = record('Comment', 1, replies: replies)
    after = before.with_association('replies', more)
    first = collection(before, record('Comment', 2))
    second = first.transition_to([after, first.records.last], before: before, after: after)

    expect(held(root(comments: first))).to eq('Comment' => [1, 2], 'Reply' => [1])
    expect(held(root(comments: second))).to eq('Comment' => [1, 2], 'Reply' => [1, 2])
    expect(held(root(comments: first))).to eq('Comment' => [1, 2], 'Reply' => [1])
  end

  it 'compares two collections no transition joins' do
    kept = [record('Comment', 1), record('Comment', 4)]
    first = collection(kept.first, record('Comment', 2, replies: collection(record('Reply', 2))),
                       kept.last)
    second = collection(kept.first, record('Comment', 2), record('Comment', 3), kept.last)

    expect(held(root(comments: first))).to eq('Comment' => [1, 2, 4], 'Reply' => [2])
    expect(held(root(comments: second))).to eq('Comment' => [1, 2, 3, 4], 'Reply' => [])
    expect(held(root(comments: collection))).to eq('Comment' => [], 'Reply' => [])
    expect(held(root(comments: first))).to eq('Comment' => [1, 2, 4], 'Reply' => [2])
  end

  it 'holds a record for as long as any place does' do
    shared = record('Reply', 1)
    both = collection(record('Comment', 1, replies: collection(shared)),
                      record('Comment', 2, replies: collection(shared)))
    one = collection(record('Comment', 1), record('Comment', 2, replies: collection(shared)))

    expect(held(root(comments: both))).to eq('Comment' => [1, 2], 'Reply' => [1])
    expect(held(root(comments: one))).to eq('Comment' => [1, 2], 'Reply' => [1])
    expect(held(root(comments: collection(record('Comment',
                                                 1))))).to eq('Comment' => [1], 'Reply' => [])
  end

  it 'reads an association a snapshot gains or loses' do
    expect(held(root)).to eq('Comment' => [], 'Reply' => [])
    expect(held(root(comments: collection(record('Comment',
                                                 1))))).to eq('Comment' => [1], 'Reply' => [])
    expect(held(root)).to eq('Comment' => [], 'Reply' => [])
  end
end
