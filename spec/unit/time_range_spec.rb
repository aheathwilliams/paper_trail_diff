# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::TimeRange do
  let(:start_time) { Time.utc(2032, 1, 1, 12) }
  let(:end_time) { start_time + 3600 }

  def invalid(message)
    raise_error(PaperTrailDiff::InvalidTimeRangeError, message)
  end

  it 'honors inclusive and exclusive Ruby range ends' do
    inclusive = described_class.new(start_time..end_time)
    exclusive = described_class.new(start_time...end_time)

    expect(inclusive.include?(start_time)).to be(true)
    expect(inclusive.include?(end_time)).to be(true)
    expect(inclusive.include?(start_time - 1)).to be(false)
    expect(exclusive.include?(end_time)).to be(false)
    expect(exclusive.include?(end_time - 1)).to be(true)
    expect(exclusive.exclude_end?).to be(true)
    expect(inclusive.exclude_end?).to be(false)
    expect(inclusive).to be_frozen
  end

  it 'rejects open, non-time, and reversed ranges' do
    expect { described_class.new(Range.new(nil, end_time)) }
      .to invalid('`within` must be a finite Range')
    expect { described_class.new(start_time..) }.to invalid('`within` must be a finite Range')
    expect { described_class.new(1..2) }.to invalid('`within` begin must be time-like')
    expect { described_class.new(end_time..start_time) }
      .to invalid('`within` beginning must not follow its end')
  end

  it 'accepts only a Range, including a subclass of one' do
    lookalike = Struct.new(:begin, :end).new(start_time, end_time)
    subclass = Class.new(Range)

    expect { described_class.new(lookalike) }.to invalid('`within` must be a finite Range')
    expect(described_class.new(subclass.new(start_time, end_time)).end_time).to eq(end_time)
  end

  it 'names the boundary that is not a time, and keeps the cause' do
    expect { described_class.new('2032-01-01'..'nonsense') }
      .to invalid('`within` end must be time-like')
    expect { described_class.new(start_time..end_time).include?(:soon) }
      .to invalid('`within` timestamp must be time-like')
    expect { described_class.new('nonsense'..'now') }
      .to(raise_error { |error| expect(error.cause).to be_a(NoMethodError) })
  end

  it 'normalizes zoned values to their UTC instants' do
    zone = ActiveSupport::TimeZone['America/Chicago']
    zoned_start = zone.local(2032, 1, 1, 6)
    range = described_class.new(zoned_start...(zoned_start + 3600))

    expect(range.begin_time).to eq(Time.utc(2032, 1, 1, 12))
    expect(range.end_time).to eq(Time.utc(2032, 1, 1, 13))
  end

  it 'converts dates, date-times, and strings, and freezes the result' do
    range = described_class.new(
      DateTime.new(2032, 1, 1, 6, 0, 0, '-06:00')..'2032-01-01T13:00:00.5Z'
    )

    expect(range.begin_time).to eq(start_time)
    expect(range.end_time).to eq(Time.utc(2032, 1, 1, 13, 0, 0.5r))
    expect([range.begin_time, range.end_time]).to all(be_frozen.and(be_utc))
    expect(described_class.new(Date.new(2032, 1, 1)..Date.new(2032, 1, 2)).begin_time)
      .to eq(Date.new(2032, 1, 1).to_time.getutc)
  end

  describe 'version queries' do
    before { FilterVersion.delete_all }

    def version(item_id, created_at)
      FilterVersion.create!(item_type: 'FilterArticle', item_id: item_id, event: 'update',
                            created_at: created_at)
    end

    let(:relation) { FilterVersion.where(item_type: 'FilterArticle') }

    it 'scopes to versions inside the range' do
      inside = version(1, start_time)
      at_end = version(1, end_time)
      version(1, start_time - 1)
      version(1, end_time + 1)

      expect(described_class.new(start_time..end_time).scope(relation))
        .to contain_exactly(inside, at_end)
      expect(described_class.new(start_time...end_time).scope(relation)).to contain_exactly(inside)
    end

    it 'scopes to versions after the range, counting an excluded end as after' do
      version(1, end_time - 1)
      at_end = version(1, end_time)
      later = version(1, end_time + 1)

      expect(described_class.new(start_time..end_time).trailing_scope(relation))
        .to contain_exactly(later)
      expect(described_class.new(start_time...end_time).trailing_scope(relation))
        .to contain_exactly(at_end, later)
    end

    it "finds each item's first version after the range, loading only that one" do
      version(1, end_time)
      first = version(1, end_time + 10)
      version(1, end_time + 20)
      other = version(2, end_time + 30)
      version(2, end_time - 10)
      loaded = []
      count = ->(*, payload) { loaded << payload[:record_count] }

      found = ActiveSupport::Notifications.subscribed(count, 'instantiation.active_record') do
        described_class.new(start_time..end_time).first_trailing_versions(relation)
      end

      expect(found).to eq('1' => first, '2' => other)
      expect(loaded).to eq([2])
    end

    # The relation's own order is replaced, so ties fall to id even when it
    # asks for the opposite.
    it 'keeps the earlier id when the first versions after the range share a timestamp' do
      lower = version(1, end_time + 10)
      version(1, end_time + 10)
      descending = relation.order(id: :desc)

      expect(described_class.new(start_time..end_time).first_trailing_versions(descending))
        .to eq('1' => lower)
    end

    it 'counts a version at an excluded end as the first one after the range' do
      at_end = version(1, end_time)
      version(1, end_time + 10)

      expect(described_class.new(start_time...end_time).first_trailing_versions(relation))
        .to eq('1' => at_end)
    end
  end
end
