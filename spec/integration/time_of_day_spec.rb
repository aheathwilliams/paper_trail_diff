# frozen_string_literal: true

require_relative '../support/core_database'

ActiveRecord::Schema.define do
  create_table :alarm_clocks, force: true do |table|
    table.string :name, null: false
    table.time :rings_at
  end
end

class AlarmClock < ActiveRecord::Base
  has_paper_trail
end

# As a Rails app's models are by default.
class ZonedAlarmClock < ActiveRecord::Base
  self.table_name = 'alarm_clocks'
  self.time_zone_aware_attributes = true
  self.time_zone_aware_types = %i[datetime time]
  has_paper_trail
end

# An initialization callback makes the gem rebuild each version with
# PaperTrail's reify, which it cannot read directly.
class CallbackAlarmClock < ActiveRecord::Base
  self.table_name = 'alarm_clocks'
  after_initialize { @initialized = true }
  has_paper_trail
end

# PaperTrail's YAML serializer stores a time column's value as the
# ActiveRecord::Type::Time::Value that wraps it.
RSpec.describe 'History of a time of day' do
  # A zone-aware time stored as a TimeWithZone's fields names its zone. SQL
  # Server's adapter stores a time as its own type instead.
  def time_classes
    classes = [ActiveRecord::Type::Time::Value, ActiveSupport::TimeWithZone,
               ActiveSupport::TimeZone]
    return classes unless ActiveRecord::Base.connection.adapter_name == 'SQLServer'

    classes + [ActiveRecord::ConnectionAdapters::SQLServer::Type::Time]
  end

  around do |example|
    permitted = ActiveRecord.yaml_column_permitted_classes
    ActiveRecord.yaml_column_permitted_classes = permitted + time_classes
    example.run
  ensure
    ActiveRecord.yaml_column_permitted_classes = permitted
  end

  before do
    PaperTrail::Version.delete_all
    AlarmClock.delete_all
  end

  # In UTC, a zone-aware time is stored as a TimeWithZone's fields under the
  # wrapper's tag, which PaperTrail reads; in any other zone, it wraps its time.
  # Each time falls in UTC on another day than in its zone: Active Record
  # before 8.1 then reads a zone-aware one from the database on another date
  # than it assigns it.
  zones = { 'UTC' => '07:30', 'Pacific/Auckland' => '07:30', 'Pacific/Honolulu' => '20:00' }
  [AlarmClock, ZonedAlarmClock, CallbackAlarmClock].product(zones.to_a).each do |model, (zone, at)|
    context "with #{model.name} in #{zone}" do
      around { |example| Time.use_zone(zone) { example.run } }

      # What a version recorded reads as a step's diff does: on 2000-01-01 in
      # the time's own zone, as Active Record 8.1 reads a row (see TimeOfDay).
      # Before 8.1 a zone-aware time reloaded from the row falls on that date
      # in UTC instead, a day apart here.
      def as_recorded(time)
        time.change(year: 2000, month: 1, day: 1)
      end

      it 'reads the time each version recorded' do
        clock = model.create!(name: 'Kitchen')
        clock.update!(rings_at: at)
        clock.update!(name: 'Bedroom')
        clock.reload
        _created, set, renamed = clock.versions.reorder(:created_at, :id).to_a

        [SpecTimelines.timeline(clock), SpecTimelines.activity_timeline(clock)].each do |steps|
          expect(steps.drop(1).map { |step| step.diff.attributes.keys })
            .to eq([['rings_at'], ['name']])
        end
        expect(PaperTrailDiff.compare(renamed, clock).attributes.keys).to eq(['name'])
        expect(PaperTrailDiff.recorded_changes(set).transform_values(&:to_h))
          .to eq('rings_at' => { from: nil, to: as_recorded(clock.rings_at) })
      end

      # Active Record keeps the date of a time assigned in memory, and the
      # versions saved from that instance store it, while the row keeps only
      # the time. Without zone conversion nothing drops the date first.
      it 'reads a time assigned with a date as the row keeps it' do
        clock = model.create!(name: 'Kitchen')
        clock.update!(rings_at: Time.zone.parse("2032-03-04 #{at}"))
        clock.update!(name: 'Bedroom')
        clock.update!(name: 'Hall')
        clock.reload
        _created, set, renamed, = clock.versions.reorder(:created_at, :id).to_a

        [SpecTimelines.timeline(clock), SpecTimelines.activity_timeline(clock),
         PaperTrailDiff.report(model, since: Time.now.utc - 3600, limit: 1)
                       .analyses.values.first.activity_timeline].each do |steps|
          expect(steps.drop(1).map { |step| step.diff.attributes.keys })
            .to eq([['rings_at'], ['name'], ['name']])
        end
        expect(PaperTrailDiff.compare(renamed, clock).attributes.keys).to eq(['name'])
        expect(PaperTrailDiff.recorded_changes(set).fetch('rings_at').to)
          .to eq(as_recorded(clock.rings_at))
      end
    end
  end

  it 'gives a callable historical_filter: the time each version recorded' do
    clock = AlarmClock.create!(name: 'Kitchen', rings_at: '07:30')
    clock.update!(name: 'Bedroom')
    seen = []
    filter = lambda do |state|
      seen << state.rings_at
      true
    end

    PaperTrailDiff.analyze_scope(
      AlarmClock, limit: 1, within: (Time.now.utc - 3600)..(Time.now.utc + 60),
                  historical_filter: filter
    )

    expect(seen).not_to be_empty
    expect(seen).to all(eq(clock.reload.rings_at))
  end
end
