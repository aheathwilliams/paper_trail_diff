# frozen_string_literal: true

RSpec.describe PaperTrailDiff::TimeOfDay do
  # A model with a time column, `rings_at`, and a datetime one, `alarm_set_at`.
  def model(types = { 'rings_at' => ActiveModel::Type::Time.new,
                      'alarm_set_at' => ActiveModel::Type::DateTime.new })
    Class.new do
      define_singleton_method(:attribute_types) { types }
    end
  end

  it 'reads a time of day on 2000-01-01, keeping its time and zone' do
    zoned = Time.use_zone('Pacific/Auckland') { Time.zone.local(2000, 1, 2, 7, 30, 15) }
    offset = Time.new(2032, 3, 4, 20, 0, Rational(1, 2), '-10:00')
    clock = model

    read = described_class.apply(clock, 'rings_at' => zoned, 'alarm_set_at' => zoned)
    expect(read).to eq('rings_at' => zoned - 86_400, 'alarm_set_at' => zoned)
    expect(read.fetch('rings_at').time_zone).to eq(zoned.time_zone)
    expect(described_class.apply(clock, 'rings_at' => offset))
      .to eq('rings_at' => Time.new(2000, 1, 1, 20, 0, Rational(1, 2), '-10:00'))
    expect(described_class.apply(clock, 'rings_at' => nil)).to eq('rings_at' => nil)
  end

  it 'leaves the attributes of a model without a time column as they are' do
    attributes = { 'alarm_set_at' => Time.utc(2032, 3, 4) }
    alarm = model('alarm_set_at' => ActiveModel::Type::DateTime.new)

    expect(described_class.apply(alarm, attributes)).to equal(attributes)
  end

  it "reads a model's time columns once" do
    clock = model
    allow(clock).to receive(:attribute_types).and_call_original

    2.times { described_class.apply(clock, 'rings_at' => nil) }

    expect(clock).to have_received(:attribute_types).once
  end
end
