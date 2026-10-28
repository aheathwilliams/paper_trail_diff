# frozen_string_literal: true

RSpec.describe PaperTrailDiff::StoredTimePrecision do
  let(:precise) { Time.utc(2032, 1, 1, 12, 0, 0, Rational(123_456_789, 1000)) }

  def model_with_history(object_type: :text, versioned: true)
    columns = {
      'object' => Struct.new(:type).new(object_type),
      'object_changes' => Struct.new(:type).new(:text)
    }
    version_class = Struct.new(:columns_hash).new(columns)
    Struct.new(:paper_trail_options, :paper_trail).new(
      versioned ? {} : nil, Struct.new(:version_class).new(version_class)
    )
  end

  it 'truncates times, and only times, to the stored digits' do
    attributes = described_class.apply({ 'at' => precise, 'title' => 'Draft' }, 3)

    expect(attributes.fetch('at').nsec).to eq(123_000_000)
    expect(attributes.fetch('title')).to eq('Draft')
    expect(described_class.truncate(precise, 0).nsec).to eq(0)
    expect(described_class.truncate(precise, 9)).to equal(precise)
  end

  it 'keeps a time already at the stored precision and zoned times in their zone' do
    stored = described_class.truncate(precise, 3)
    zoned = precise.in_time_zone('America/Chicago')

    expect(described_class.truncate(stored, 3)).to equal(stored)
    expect(described_class.truncate(zoned, 6).time_zone).to eq(zoned.time_zone)
    expect(described_class.truncate(zoned, 6).nsec).to eq(123_456_000)
  end

  it 'leaves attributes alone when history is lossless' do
    attributes = { 'at' => precise }

    expect(described_class.apply(attributes, nil)).to equal(attributes)
  end

  it 'reads JSON precision from the version columns or the serializer' do
    original = PaperTrail.serializer
    PaperTrail.serializer = PaperTrail::Serializers::YAML

    expect(described_class.digits(model_with_history)).to be_nil
    expect(described_class.digits(model_with_history(versioned: false))).to be_nil
    expect(described_class.digits(model_with_history(object_type: :jsonb)))
      .to eq(ActiveSupport::JSON::Encoding.time_precision)

    PaperTrail.serializer = PaperTrail::Serializers::JSON
    expect(described_class.digits(model_with_history))
      .to eq(ActiveSupport::JSON::Encoding.time_precision)
  ensure
    PaperTrail.serializer = original
  end
end
