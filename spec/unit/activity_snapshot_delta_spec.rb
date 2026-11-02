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

  # A has_many's reflection; only one declared with `as:` has a type column.
  def reflection(foreign_key, as: nil)
    reflection_class = ActiveRecord::Reflection::HasManyReflection
    return instance_double(reflection_class, foreign_key: foreign_key, options: {}) unless as

    instance_double(reflection_class, foreign_key: foreign_key, options: { as: as },
                                      type: "#{as}_type")
  end

  it 'applies deserialized after values while preserving identity and associations' do
    replies = PaperTrailDiff::AssociationSnapshot.new(kind: :has_many, records: [])
    before = snapshot(body: 'Before', associations: { replies: replies })
    delta = described_class.new(
      before_attributes: { body: 'Before', stable: 'value', ignored: 'old' },
      after_attributes: { body: 'After', ignored: 'new' }
    )

    after = delta.apply(before)

    expect(delta).to be_frozen
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
    delta = described_class.new(
      before_attributes: { article_id: 1 },
      after_attributes: { article_id: 2 }
    )

    expect(delta.before_value(:article_id)).to eq(1)
    expect(delta.after_value(:article_id)).to eq(2)
    expect(delta.relationship_changed?(reflection('article_id'))).to be(true)
  end

  it 'uses optional before attributes for unchanged nested ownership' do
    delta = described_class.new(
      before_attributes: { comment_id: 12, body: 'Before' },
      after_attributes: { comment_id: 12, body: 'After' }
    )

    expect(delta.before_value(:comment_id)).to eq(12)
    expect(delta.after_value(:comment_id)).to eq(12)
    expect(delta.relationship_changed?(reflection('comment_id'))).to be(false)
  end

  it 'reads a column neither side recorded as nil, and as unchanged' do
    delta = described_class.new(before_attributes: { body: 'Before' },
                                after_attributes: { body: 'After' })

    expect([delta.before_value(:reviewer_id), delta.after_value(:reviewer_id)]).to eq([nil, nil])
    expect([delta.changed?(:reviewer_id), delta.changed?(:body)]).to eq([false, true])
  end

  it 'compares values as text, so an id read as a string matches the integer' do
    delta = described_class.new(before_attributes: { article_id: 1 },
                                after_attributes: { article_id: '1' })

    expect(delta.changed?(:article_id)).to be(false)
  end

  it 'detects a polymorphic owner type change' do
    delta = described_class.new(
      before_attributes: { subject_id: 1, subject_type: 'Article' },
      after_attributes: { subject_id: 1, subject_type: 'Profile' }
    )

    expect(delta.relationship_changed?(reflection('subject_id', as: :subject))).to be(true)
  end

  it 'detects a change to any column of a composite foreign key' do
    delta = described_class.new(
      before_attributes: { shop_id: 1, article_id: 2, tenant_id: 5 },
      after_attributes: { shop_id: 1, article_id: 3, tenant_id: 5 }
    )

    expect(delta.relationship_changed?(reflection(%w[shop_id article_id]))).to be(true)
    expect(delta.relationship_changed?(reflection(%w[shop_id tenant_id]))).to be(false)
  end
end
