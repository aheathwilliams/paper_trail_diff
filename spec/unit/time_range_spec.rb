# frozen_string_literal: true

RSpec.describe PaperTrailDiff::TimeRange do
  let(:start_time) { Time.utc(2032, 1, 1, 12) }
  let(:end_time) { start_time + 3600 }

  it 'honors inclusive and exclusive Ruby range ends' do
    inclusive = described_class.new(start_time..end_time)
    exclusive = described_class.new(start_time...end_time)

    expect(inclusive.include?(start_time)).to be(true)
    expect(inclusive.include?(end_time)).to be(true)
    expect(inclusive.include?(start_time - 1)).to be(false)
    expect(exclusive.include?(end_time)).to be(false)
    expect(exclusive.exclude_end?).to be(true)
    expect(inclusive).to be_frozen
  end

  it 'rejects open, non-time, and reversed ranges' do
    expect { described_class.new(Range.new(nil, end_time)) }
      .to raise_error(PaperTrailDiff::InvalidTimeRangeError, /finite Range/)
    expect { described_class.new(1..2) }
      .to raise_error(PaperTrailDiff::InvalidTimeRangeError, /time-like/)
    expect { described_class.new(end_time..start_time) }
      .to raise_error(PaperTrailDiff::InvalidTimeRangeError, /must not follow/)
  end

  it 'normalizes zoned values to their UTC instants' do
    zone = ActiveSupport::TimeZone['America/Chicago']
    zoned_start = zone.local(2032, 1, 1, 6)
    range = described_class.new(zoned_start...(zoned_start + 3600))

    expect(range.begin_time).to eq(Time.utc(2032, 1, 1, 12))
    expect(range.end_time).to eq(Time.utc(2032, 1, 1, 13))
  end
end
