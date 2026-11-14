# frozen_string_literal: true

RSpec.describe PaperTrailDiff::StoredJsonValues do
  let(:serialized) { ActiveRecord::Type::Serialized.new(ActiveModel::Type::String.new, YAML) }
  let(:meta) { { due: Date.new(2026, 11, 3), state: :draft } }
  let(:written) { { 'due' => '2026-11-03', 'state' => 'draft' } }

  # A model with a serialized `meta` and a binary `blob`, whose versions keep
  # their `object` in a column of this type.
  def apply(object_type, attributes)
    columns = { 'object' => Struct.new(:type).new(object_type) }
    paper_trail = Struct.new(:version_class).new(Struct.new(:columns_hash).new(columns))
    # An adapter's binary type, as PostgreSQL's `bytea` is.
    types = { 'meta' => serialized, 'blob' => Class.new(ActiveModel::Type::Binary).new }
    model = Struct.new(:paper_trail) do
      define_method(:attribute_types) { types.merge('title' => ActiveModel::Type::Value.new) }
    end
    described_class.apply(model.new(paper_trail), attributes)
  end

  it 'reads a serialized value as JSON writes it from a json or jsonb object column' do
    attributes = { 'meta' => meta, 'blob' => 'bytes', 'title' => :draft }
    expected = { 'meta' => written, 'blob' => 'bytes', 'title' => :draft }

    expect(apply(:json, attributes)).to eq(expected)
    expect(apply(:jsonb, attributes)).to eq(expected)
    expect(apply(:json, 'meta' => written)).to eq('meta' => written)
  end

  it 'reads a binary value the JSON serializer wrapped as its bytes' do
    read = apply(:text, 'blob' => { 'value' => 'bytes' }, 'meta' => { 'value' => 'kept' })

    expect(read).to eq('blob' => 'bytes', 'meta' => { 'value' => 'kept' })
    expect(read.fetch('blob').encoding).to eq(Encoding::BINARY)
    expect(apply(:text, 'blob' => 'bytes', 'meta' => meta)).to eq('blob' => 'bytes', 'meta' => meta)
    expect(apply(:text, 'blob' => { 'value' => 'x', 'size' => 1 }))
      .to eq('blob' => { 'value' => 'x', 'size' => 1 })
  end
end
