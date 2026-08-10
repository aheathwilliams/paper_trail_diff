# frozen_string_literal: true

RSpec.describe PaperTrailDiff::ActivitySnapshotDelta do
  def snapshot(body:, associations: {})
    PaperTrailDiff::RecordSnapshot.new(
      type: 'Comment',
      id: 7,
      attributes: { body: body, stable: 'value' },
      associations: associations
    )
  end

  it 'applies deserialized after values while preserving identity and associations' do
    replies = PaperTrailDiff::AssociationSnapshot.new(kind: :has_many, records: [])
    before = snapshot(body: 'Before', associations: { replies: replies })
    delta = described_class.new(
      before_attributes: { body: 'Before', stable: 'value', ignored: 'old' },
      after_attributes: { body: 'After', ignored: 'new' }
    )

    after = delta.apply(before)

    expect(after.type).to eq(before.type)
    expect(after.id).to eq(before.id)
    expect(after.attributes).to eq('body' => 'After', 'stable' => 'value')
    expect(after.associations.fetch('replies')).to equal(replies)
  end

  it 'reuses the snapshot when prepared attributes did not change' do
    record = snapshot(body: 'Same')
    delta = described_class.new(
      before_attributes: record.attributes,
      after_attributes: record.attributes
    )

    expect(delta.apply(record)).to equal(record)
  end

  it 'reads changed relationship values without requiring a full before object' do
    reflection = Struct.new(:foreign_key, :options).new(:article_id, {})
    delta = described_class.new(
      before_attributes: { article_id: 1 },
      after_attributes: { article_id: 2 }
    )

    expect(delta.before_value(:article_id)).to eq(1)
    expect(delta.after_value(:article_id)).to eq(2)
    expect(delta.relationship_changed?(reflection)).to be(true)
  end

  it 'uses optional before attributes for unchanged nested ownership' do
    reflection = Struct.new(:foreign_key, :options).new(:comment_id, {})
    delta = described_class.new(
      before_attributes: { comment_id: 12, body: 'Before' },
      after_attributes: { comment_id: 12, body: 'After' }
    )

    expect(delta.before_value(:comment_id)).to eq(12)
    expect(delta.after_value(:comment_id)).to eq(12)
    expect(delta.relationship_changed?(reflection)).to be(false)
  end

  it 'detects a polymorphic owner type change' do
    reflection = Struct.new(:foreign_key, :options, :type).new(
      :subject_id,
      { as: :subject },
      :subject_type
    )
    delta = described_class.new(
      before_attributes: { subject_id: 1, subject_type: 'Article' },
      after_attributes: { subject_id: 1, subject_type: 'Profile' }
    )

    expect(delta.relationship_changed?(reflection)).to be(true)
  end
end
