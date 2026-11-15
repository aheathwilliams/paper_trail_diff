# frozen_string_literal: true

RSpec.describe PaperTrailDiff::DatabaseTime do
  def model(types)
    Class.new do
      define_singleton_method(:attribute_types) { types }
    end
  end

  # Ruby reads TZ again when it changes, so local time is told from UTC.
  # A POSIX zone four hours behind UTC, with no daylight saving, which
  # Windows reads as well (it knows no IANA names).
  around do |example|
    zone = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'XYZ4'
    example.run
  ensure
    ENV['TZ'] = zone
  end

  def in_local_time
    default = ActiveRecord.default_timezone
    ActiveRecord.default_timezone = :local
    yield
  ensure
    ActiveRecord.default_timezone = default
  end

  # A Date equals the Time of its midnight, so the class is checked too.
  def time(value)
    [value.class, value, value.utc_offset]
  end

  describe '.stored' do
    it 'reads a date, or a date written as text, as midnight in UTC' do
      expect(time(described_class.stored(Date.new(2032, 3, 2)))).to eq(time(Time.utc(2032, 3, 2)))
      expect(time(described_class.stored('2032-03-02'))).to eq(time(Time.utc(2032, 3, 2)))
      expect(described_class.stored(['2032-03-02', Date.new(2032, 3, 3)]).map do |value|
        time(value)
      end)
        .to eq([time(Time.utc(2032, 3, 2)), time(Time.utc(2032, 3, 3))])
    end

    it 'reads a date as midnight where the database keeps local time' do
      in_local_time do
        read = described_class.stored('2032-07-02')

        expect(read).to eq(Time.local(2032, 7, 2))
        expect(read.utc_offset).to eq(-4 * 3600)
        expect(described_class.stored(Date.new(2032, 7, 2)).utc_offset).to eq(-4 * 3600)
      end
    end

    it 'leaves anything else as it is' do
      time = Time.utc(2032, 1, 2, 10)
      moment = DateTime.new(2032, 1, 2, 10)

      expect(described_class.stored(time)).to equal(time)
      expect(described_class.stored(moment)).to equal(moment)
      expect(described_class.stored('2032-01-02 10:00:00')).to equal('2032-01-02 10:00:00')
      expect(described_class.stored('2032-13-45')).to equal('2032-13-45')
      expect(described_class.stored('20320102')).to equal('20320102')
      expect(described_class.stored(' 2032-01-02')).to equal(' 2032-01-02')
      expect(described_class.stored(nil)).to be_nil
      expect(described_class.stored([nil, time])).to eq([nil, time])
    end
  end

  describe '.cast' do
    it 'reads a date, or text, in UTC unless the text names its offset' do
      expect(time(described_class.cast(Date.new(2032, 3, 2)))).to eq(time(Time.utc(2032, 3, 2)))
      expect(described_class.cast('2032-01-02 10:00')).to eq(Time.utc(2032, 1, 2, 10))
      expect(described_class.cast('2032-01-02 10:00 +02:00')).to eq(Time.utc(2032, 1, 2, 8))
      expect(described_class.cast('2032-01-02 10:00').utc_offset).to eq(0)
    end

    it 'reads text in local time where the database keeps it' do
      in_local_time do
        expect(described_class.cast('2032-07-02 10:00').utc_offset).to eq(-4 * 3600)
        expect(described_class.cast('2032-07-02 10:00')).to eq(Time.local(2032, 7, 2, 10))
        expect(described_class.cast('soon')).to eq('soon')
      end
    end

    it 'leaves anything else, and text that names no time, as it is' do
      time = Time.utc(2032, 1, 2, 10)

      expect(described_class.cast(time)).to equal(time)
      expect(described_class.cast(7)).to eq(7)
      text = Class.new(String).new('2032-01-02 10:00')
      expect(described_class.cast(text)).to equal(text)
      expect(described_class.cast('soon')).to equal('soon')
      expect(described_class.cast('')).to equal('')
    end
  end

  describe '.stored_date?' do
    let(:dated) { model('starts_at' => ActiveModel::Type::DateTime.new) }

    it 'finds a date with no time in YAML or JSON text' do
      expect(described_class.stored_date?("starts_at: 2032-01-02\n", dated)).to be(true)
      expect(described_class.stored_date?('starts_at: 2032-01-02', dated)).to be(true)
      expect(described_class.stored_date?('{"starts_at":"2032-01-02"}', dated)).to be(true)
      expect(described_class.stored_date?("starts_at: 2032-01-02 10:00:00\n", dated)).to be(false)
      expect(described_class.stored_date?('{"starts_at":"2032-01-02T10:00:00Z"}',
                                          dated)).to be(false)
      expect(described_class.stored_date?("starts_at:2032-01-02x\n", dated)).to be(false)
    end

    it 'finds a date with no time among stored values' do
      expect(described_class.stored_date?({ 'starts_at' => '2032-01-02' }, dated)).to be(true)
      expect(described_class.stored_date?({ 'a' => 1, 'starts_at' => '2032-01-02' },
                                          dated)).to be(true)
      expect(described_class.stored_date?({ 'starts_at' => '2032-01-02T10:00' },
                                          dated)).to be(false)
      expect(described_class.stored_date?({ 'starts_at' => Date.new(2032, 1, 2) },
                                          dated)).to be(false)
      expect(described_class.stored_date?({ 'starts_at' => 'on 2032-01-02' }, dated)).to be(false)
      expect(described_class.stored_date?(nil, dated)).to be(false)
      expect(described_class.stored_date?(Class.new(String).new("a: 2032-01-02\n"),
                                          dated)).to be(false)
      expect(described_class.stored_date?({ 'a' => Class.new(String).new('2032-01-02') }, dated))
        .to be(false)
      expect(described_class.stored_date?(['2032-01-02'], dated)).to be(false)
    end

    it 'finds none for a model without a datetime column' do
      plain = model('due_on' => ActiveModel::Type::Date.new)

      expect(described_class.stored_date?("due_on: 2032-01-02\n", plain)).to be(false)
      expect(described_class.stored_date?({ 'due_on' => '2032-01-02' }, plain)).to be(false)
    end
  end
end
