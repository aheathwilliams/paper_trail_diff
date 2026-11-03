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

# PaperTrail's YAML serializer stores a time column's value as the
# ActiveRecord::Type::Time::Value that wraps it.
RSpec.describe 'History of a time of day' do
  # SQL Server's adapter stores a time as its own type instead.
  def time_classes
    classes = [ActiveRecord::Type::Time::Value]
    return classes unless ActiveRecord::Base.connection.adapter_name == 'SQLServer'

    classes + [ActiveRecord::ConnectionAdapters::SQLServer::Type::Time]
  end

  around do |example|
    permitted = ActiveRecord.yaml_column_permitted_classes
    ActiveRecord.yaml_column_permitted_classes = permitted + time_classes
    Time.use_zone('Pacific/Auckland') { example.run }
  ensure
    ActiveRecord.yaml_column_permitted_classes = permitted
  end

  before do
    PaperTrail::Version.delete_all
    AlarmClock.delete_all
  end

  [AlarmClock, ZonedAlarmClock].each do |model|
    context "with #{model.name}" do
      it 'reads the time each version recorded' do
        clock = model.create!(name: 'Kitchen')
        clock.update!(rings_at: '07:30')
        clock.update!(name: 'Bedroom')
        clock.reload
        _created, set, renamed = clock.versions.reorder(:created_at, :id).to_a

        [PaperTrailDiff.timeline(clock), PaperTrailDiff.activity_timeline(clock)].each do |steps|
          expect(steps.drop(1).map { |step| step.diff.attributes.keys })
            .to eq([['rings_at'], ['name']])
        end
        expect(PaperTrailDiff.compare(renamed, clock).attributes.keys).to eq(['name'])
        expect(PaperTrailDiff.recorded_changes(set).transform_values(&:to_h))
          .to eq('rings_at' => { from: nil, to: clock.rings_at })
      end
    end
  end
end
