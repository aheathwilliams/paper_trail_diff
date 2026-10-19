# frozen_string_literal: true

# The suites build windows from `Time.now` around versions they just wrote, so
# the test clock must not follow a host clock that steps backwards.
RSpec.describe MonotonicTestClock do
  it 'keeps readings strictly increasing in whole microseconds across a backward step' do
    start = Time.now
    stepped_back = start - 0.5
    later = described_class.next_after(stepped_back)
    same_instant = described_class.next_after(stepped_back)

    expect(later).to be > start
    expect(same_instant).to be > later
    expect((same_instant.to_r - later.to_r) * 1_000_000).to eq(1)
    expect(later.nsec % 1000).to eq(0)
  end

  it 'keeps the zone of the reading it adjusts' do
    zoned = described_class.next_after(Time.now.getlocal('+09:00') - 1)

    expect(zoned.utc_offset).to eq(9 * 3600)
  end

  it 'follows a timestamp assigned slightly ahead, but not a far-future fixture' do
    ahead = Time.now + 0.2
    described_class.advance_past(ahead)
    described_class.advance_past(Time.utc(2099))

    expect(Time.now).to be > ahead
    expect(Time.now.year).to be < 2099
  end
end
