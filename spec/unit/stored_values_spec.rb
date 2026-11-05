# frozen_string_literal: true

require 'paper_trail_diff'

RSpec.describe PaperTrailDiff::StoredValues do
  let(:precise) { Time.utc(2032, 1, 1, 12, 0, 0, Rational(123_456_789, 1000)) }
  let(:values) do
    { 'rings_at' => Time.utc(2032, 3, 4, 7, 30), 'at' => precise, 'blob' => { 'value' => 'x' } }
  end

  # A versioned model with a time of day, a time, and a binary column, whose
  # history is a text column written with the serializer in use.
  def model
    types = { 'rings_at' => ActiveModel::Type::Time.new,
              'at' => ActiveModel::Type::DateTime.new,
              'blob' => ActiveModel::Type::Binary.new }
    columns = %w[object object_changes].to_h { |name| [name, Struct.new(:type).new(:text)] }
    paper_trail = Struct.new(:version_class).new(Struct.new(:columns_hash).new(columns))
    Class.new do
      define_singleton_method(:attribute_types) { types }
      define_singleton_method(:type_for_attribute) { |name| types.fetch(name) }
      define_singleton_method(:paper_trail_options) { {} }
      define_singleton_method(:paper_trail) { paper_trail }
    end
  end

  def with_serializer(serializer)
    original = PaperTrail.serializer
    PaperTrail.serializer = serializer
    yield
  ensure
    PaperTrail.serializer = original
  end

  it 'reads a time of day on 2000-01-01 and leaves lossless history as it is' do
    read = with_serializer(PaperTrail::Serializers::YAML) { described_class.apply(model, values) }

    expect(read).to eq(values.merge('rings_at' => Time.utc(2000, 1, 1, 7, 30)))
  end

  it 'reads JSON history in the form JSON stored it' do
    read = with_serializer(PaperTrail::Serializers::JSON) { described_class.apply(model, values) }

    expect(read.fetch('rings_at')).to eq(Time.utc(2000, 1, 1, 7, 30))
    expect(read.fetch('at').nsec).to eq(123_000_000)
    expect(read.fetch('blob')).to eq('x'.b)
  end
end
