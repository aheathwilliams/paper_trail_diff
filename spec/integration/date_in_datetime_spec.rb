# frozen_string_literal: true

require_relative '../support/core_database'

ActiveRecord::Schema.define do
  create_table :dated_events, force: true do |table|
    table.string :title
    table.datetime :starts_at
    table.timestamps null: false
  end
end

# As plain Active Record leaves a model, outside Rails.
class DatedEvent < ActiveRecord::Base
  has_paper_trail
end

# As a Rails app's models are by default.
class ZonedDatedEvent < ActiveRecord::Base
  self.table_name = 'dated_events'
  self.time_zone_aware_attributes = true
  has_paper_trail
end

# Active Record leaves a date assigned to a datetime column on the instance as
# it was given when nothing casts it, and PaperTrail stores it from there. The
# database keeps midnight in Active Record's default time zone, and so does
# what the gem reads from history.
RSpec.describe 'A date stored for a datetime column' do
  before do
    PaperTrail::Version.delete_all
    DatedEvent.delete_all
  end

  def with_serializer(serializer)
    previous = PaperTrail.serializer
    PaperTrail.serializer = serializer
    yield
  ensure
    PaperTrail.serializer = previous
  end

  # Active Record 8 keeps the date on the instance, and PaperTrail stores it;
  # before 8.0 the instance casts it to nil instead, and the version holds
  # that nil. The version is given the date as Active Record 8 has it stored.
  def stored_as_given(version, values)
    stored = version.object_deserialized.merge(values)
    version.update_columns(object: PaperTrail.serializer.dump(stored))
  end

  [PaperTrail::Serializers::YAML, PaperTrail::Serializers::JSON].each do |serializer|
    context "with #{serializer.name.demodulize} history" do
      around { |example| with_serializer(serializer) { example.run } }

      # The SQL Server adapter hands PaperTrail's JSON encoder a type
      # wrapper that refuses `as_json`, so there is no JSON history to read
      # there (see json_history_spec).
      before do
        ZonedDatedEvent.transaction do
          ZonedDatedEvent.create!(title: 'probe')
          raise ActiveRecord::Rollback
        end
      rescue StandardError => e
        skip "PaperTrail cannot record this history here: #{e.class}: #{e.message}"
      end

      it 'reads a date written with update_columns where the row holds it' do
        Time.use_zone('Tokyo') do
          event = ZonedDatedEvent.create!(title: 'a')
          event.update_columns(starts_at: Date.new(2026, 3, 1))
          event.update!(title: 'b') # the same instance, which still holds the date
          row = ZonedDatedEvent.find(event.id)
          stored_as_given(row.versions.last, 'starts_at' => Date.new(2026, 3, 1))

          expect(PaperTrailDiff.compare(row.versions.last, row).attributes.keys).to eq(['title'])
          starts = PaperTrailDiff.analyze(row).timeline.map do |step|
            step.diff.attributes['starts_at']
          end
          expect(starts.compact).to be_empty
        end
      end

      context 'when the database keeps local time' do
        around do |example|
          zone = ENV.fetch('TZ', nil)
          default = ActiveRecord.default_timezone
          ENV['TZ'] = 'America/New_York'
          ActiveRecord.default_timezone = :local
          example.run
        ensure
          ActiveRecord.default_timezone = default
          ENV['TZ'] = zone
        end

        it 'records a time, and reads the version as the row reads' do
          event = DatedEvent.create!(title: 'a')
          event.update!(starts_at: Date.new(2026, 3, 1))
          recorded = PaperTrailDiff.recorded_changes(event.versions.last).fetch('starts_at').to
          expect(recorded).to eq(Time.local(2026, 3, 1))
          expect(recorded).to be_a(Time)

          event.update!(title: 'b')
          row = DatedEvent.find(event.id)
          expect(PaperTrailDiff.compare(row.versions.last, row).attributes.keys).to eq(['title'])
          expect(PaperTrailDiff.compare(row.versions.second, row.versions.last).attributes.keys)
            .to eq(['starts_at'])
        end
      end
    end
  end
end
