# frozen_string_literal: true

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
