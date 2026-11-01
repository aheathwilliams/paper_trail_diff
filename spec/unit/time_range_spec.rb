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

  it 'reads back as a Ruby range with the same end' do
    expect(described_class.new(start_time..end_time).to_range).to eq(start_time..end_time)
    expect(described_class.new(start_time...end_time).to_range).to eq(start_time...end_time)
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
      .to(raise_error { |error| expect(error.cause).to be_a(ArgumentError) })
  end

  it "leaves the caller's time in its own zone" do
    local = Time.new(2032, 1, 1, 6, 0, 0, '-06:00')

    expect(described_class.new(local..(local + 60)).begin_time).to eq(Time.utc(2032, 1, 1, 12))
    expect(local.utc_offset).to eq(-21_600)
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

    expect(range.begin_time).to eq(start_time).and(be_an_instance_of(Time))
    expect(range.end_time).to eq(Time.utc(2032, 1, 1, 13, 0, 0.5r))
    expect([range.begin_time, range.end_time]).to all(be_frozen.and(be_utc))
  end

  # Read in the server's own zone, the same window covered different hours
  # on different servers.
  describe 'dates and text' do
    def in_zone(name, &)
      Time.use_zone(name, &)
    end

    # Without Time.zone, in a host zone other than UTC, so that reading the
    # host's zone is not mistaken for reading UTC on a UTC host, such as CI's.
    def without_zone(&)
      host = ENV.fetch('TZ', nil)
      ENV['TZ'] = 'America/Chicago'
      in_zone(nil, &)
    ensure
      ENV['TZ'] = host
    end

    def chicago(range)
      in_zone('America/Chicago') { described_class.new(range) }
    end

    def day = Date.new(2032, 1, 1)

    it 'reads a date as a whole day in Time.zone, through an inclusive end' do
      july = Date.new(2032, 7, 4)
      range = chicago(july..july)

      expect([range.begin_time, range.end_time, range.exclude_end?])
        .to eq([Time.utc(2032, 7, 4, 5), Time.utc(2032, 7, 5, 5), true])
      expect([range.begin_time, range.end_time]).to all(be_an_instance_of(Time).and(be_utc))
    end

    it 'ends an exclusive date end at the start of that day' do
      range = chicago(day...day.next_day)

      expect([range.end_time, range.exclude_end?]).to eq([Time.utc(2032, 1, 2, 6), true])
    end

    it 'keeps an inclusive end that names its instant' do
      range = described_class.new(Date.new(2032, 1, 1)..DateTime.new(2032, 1, 1, 12))

      expect([range.end_time, range.exclude_end?]).to eq([Time.utc(2032, 1, 1, 12), false])
    end

    it 'reads a date in UTC without Time.zone' do
      range = without_zone { described_class.new(day..day) }

      expect([range.begin_time, range.end_time]).to eq([Time.utc(2032, 1, 1), Time.utc(2032, 1, 2)])
    end

    it 'reads text as a time in Time.zone, unless it names its offset' do
      range = chicago('2032-01-01 06:00'..'2032-01-01T13:00:00Z')
      expect(range.begin_time).to be_an_instance_of(Time).and(be_utc)

      expect([range.begin_time, range.end_time])
        .to eq([Time.utc(2032, 1, 1, 12), Time.utc(2032, 1, 1, 13)])
    end

    it 'reads text of any String class, such as html_safe text' do
      start = '2032-01-01 06:00'.html_safe
      range = without_zone { described_class.new(start..'2032-01-01 07:00') }

      expect(range.begin_time).to eq(Time.utc(2032, 1, 1, 6))
    end

    it 'reads text in UTC without Time.zone' do
      range = without_zone { described_class.new('2032-01-01 06:00'..'2032-01-01 07:00') }

      expect(range.begin_time).to eq(Time.utc(2032, 1, 1, 6))
    end

    it 'includes a moment on the day a same-day date range names' do
      range = chicago(day..day)

      expect(range.include?(Time.utc(2032, 1, 2, 5, 59))).to be(true)
      expect(range.include?(Time.utc(2032, 1, 2, 6))).to be(false)
    end
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
