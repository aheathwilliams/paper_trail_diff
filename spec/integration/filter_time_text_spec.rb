# frozen_string_literal: true

require_relative '../support/core_database'

ActiveRecord::Schema.define do
  create_table :filtered_events, force: true do |table|
    table.string :title
    table.datetime :starts_at
    table.timestamps null: false
  end
end

class FilteredEvent < ActiveRecord::Base
  self.time_zone_aware_attributes = true
  has_paper_trail
end

# `where` sends text or a date given for a datetime column to the database,
# which reads it in Active Record's default time zone (UTC here), whatever
# Time.zone is. historical_filter reads it the same way.
RSpec.describe 'historical_filter given text or a date for a datetime' do
  around { |example| Time.use_zone('Tokyo') { example.run } }

  before do
    PaperTrail::Version.delete_all
    FilteredEvent.delete_all
  end

  let!(:started) { Time.current - 1 }

  def selected(value)
    { 'noon UTC' => Time.utc(2026, 3, 1, 12), 'noon Tokyo' => Time.utc(2026, 3, 1, 3),
      'midnight UTC' => Time.utc(2026, 3, 1), 'midnight Tokyo' => Time.utc(2026, 2, 28, 15) }
      .each do |title, at|
      FilteredEvent.create!(title: title,
                            starts_at: at).update!(title: "#{title}!")
    end
    PaperTrailDiff.report(FilteredEvent.all, since: started, limit: 5,
                                             historical_filter: { starts_at: value })
                  .roots.map(&:title)
  end

  it 'reads text in the database time zone, as where does' do
    expect(selected('2026-03-01 12:00:00')).to eq(['noon UTC!'])
    expect(FilteredEvent.where(starts_at: '2026-03-01 12:00:00').pluck(:title)).to eq(['noon UTC!'])
  end

  it 'reads text that names its offset at that offset' do
    expect(selected('2026-03-01 12:00:00 +09:00')).to eq(['noon Tokyo!'])
  end

  # SQLite compares the date with the stored time as text and selects
  # nothing; PostgreSQL and MySQL read it as midnight there.
  it 'reads a date as midnight in the database time zone' do
    expect(selected(Date.new(2026, 3, 1))).to eq(['midnight UTC!'])
  end
end
