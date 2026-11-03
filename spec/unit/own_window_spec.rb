# frozen_string_literal: true

RSpec.describe PaperTrailDiff::OwnWindow do
  let(:start_time) { Time.utc(2032, 1, 1, 12) }
  let(:version) { Struct.new(:id, :created_at) }

  def at(minute)
    start_time + (minute * 60)
  end

  def window(range)
    PaperTrailDiff::TimeRange.new(range)
  end

  describe '.widest' do
    it 'starts at the earliest start and keeps the end as asked' do
      moved = [window(at(1)..at(5)), window(at(0.5)...at(2))]

      expect(described_class.widest(window(at(2)..at(5)), moved).to_range).to eq(at(0.5)..at(5))
      expect(described_class.widest(window(at(2)...at(5)), moved).to_range).to eq(at(0.5)...at(5))
      expect(described_class.widest(window(at(2)..), moved).to_range).to eq(at(0.5)..)
    end

    it 'is the window as asked when nothing moved before it' do
      expect(described_class.widest(window(at(2)..at(5)), [window(at(3)..at(5))]).to_range)
        .to eq(at(2)..at(5))
    end
  end

  describe '.split' do
    it 'keeps the versions inside, and the first past the end by time then id' do
      before = version.new(1, at(0))
      inside = version.new(2, at(1))
      later = version.new(3, at(4))
      tied = [version.new(5, at(3)), version.new(4, at(3))]

      expect(described_class.split(window(at(1)...at(3)), [*tied, later, inside, before]))
        .to eq([[inside], tied.last])
    end

    it 'finds the first past the end when none is at it' do
      versions = [version.new(1, at(4)), version.new(2, at(3))]

      expect(described_class.split(window(at(1)..at(2)), versions)).to eq([[], versions.last])
    end

    it 'finds nothing past an end it includes, or past no end' do
      versions = [version.new(1, at(0)), version.new(2, at(3))]

      expect(described_class.split(window(at(1)..at(3)), versions)).to eq([[versions.last], nil])
      expect(described_class.split(window(at(1)..), versions)).to eq([[versions.last], nil])
    end
  end
end
