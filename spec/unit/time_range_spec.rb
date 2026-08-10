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

RSpec.describe PaperTrailDiff::TimelineRange do
  let(:record) { Object.new }
  let(:start_time) { Time.utc(2032, 2, 1, 12) }

  it 'distinguishes explicit endpoints from time filtering' do
    time_range = described_class.new(
      record,
      from: nil,
      to: nil,
      within: start_time...(start_time + 3600)
    )
    explicit = described_class.new(record, from: Object.new, to: Object.new, within: nil)
    version = Struct.new(:created_at).new(start_time)

    expect(time_range).to be_time
    expect(time_range.begin_time).to eq(start_time)
    expect(time_range.include?(version)).to be(true)
    expect(explicit).not_to be_time
    expect(explicit.begin_time).to be_nil
    expect(explicit.include?(version)).to be(true)
  end

  it 'rejects incomplete and mixed request modes' do
    expect do
      described_class.new(record, from: Object.new, to: nil, within: nil)
    end.to raise_error(PaperTrailDiff::InvalidTimelineRangeError, /provide both/)
    expect do
      described_class.new(
        record,
        from: Object.new,
        to: Object.new,
        within: start_time..start_time
      )
    end.to raise_error(PaperTrailDiff::InvalidTimelineRangeError, /cannot be combined/)
  end
end
