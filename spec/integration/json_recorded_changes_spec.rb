# frozen_string_literal: true

require_relative '../support/core_database'

ActiveRecord::Schema.define do
  create_table :json_ledger_versions, force: true do |table|
    table.string :item_type, null: false
    table.string :item_id, null: false
    table.string :event, null: false
    table.string :whodunnit
    table.json :object
    table.json :object_changes
    table.datetime :created_at
  end

  create_table :json_ledgers, force: true do |table|
    table.string :title, null: false
    table.decimal :price, precision: 10, scale: 2
    table.date :due
    table.datetime :seen_at
    table.time :opens_at
    table.integer :stage, default: 0, null: false
    table.text :meta
  end
end

class JsonLedgerVersion < ActiveRecord::Base
  include PaperTrail::VersionConcern
end

# A `json` object_changes column gives a decimal, a date and a time back as
# strings, and PaperTrail casts none of them.
class JsonLedger < ActiveRecord::Base
  enum :stage, { draft: 0, published: 1 }
  serialize :meta, coder: YAML, type: Hash
  has_paper_trail versions: { class_name: 'JsonLedgerVersion' }
end

RSpec.describe 'Recorded changes in a json object_changes column' do
  before do
    JsonLedgerVersion.delete_all
    JsonLedger.delete_all
    skip_unless_recordable
  end

  # As in json_history_spec: some gem and adapter combinations cannot write
  # JSON history, and SQL Server's adapter has no json column.
  def skip_unless_recordable
    skip 'the version table keeps no JSON here' unless JsonLedgerVersion.object_changes_col_is_json?
    JsonLedger.transaction do
      JsonLedger.create!(**first_values).update!(**second_values)
      raise ActiveRecord::Rollback
    end
  rescue StandardError => e
    skip "PaperTrail cannot record JSON history here: #{e.class}: #{e.message}"
  end

  def first_values
    { title: 'Draft', price: '1.10', due: Date.new(2026, 1, 2),
      seen_at: Time.utc(2026, 1, 2, 3, 4, 5), opens_at: '09:30:00', stage: :draft,
      meta: { 'tags' => %w[a] } }
  end

  def second_values
    { title: 'Published', price: '2.50', due: Date.new(2026, 2, 2),
      seen_at: Time.utc(2026, 3, 2, 3, 4, 5), opens_at: '10:45:00', stage: :published,
      meta: { 'tags' => %w[a b] } }
  end

  def edited
    ledger = JsonLedger.create!(**first_values)
    ledger.update!(**second_values)
    ledger.reload
  end

  def pairs(changes)
    changes.transform_values { |change| [change.from, change.to] }
  end

  it 'casts each value to its attribute type, as the step for the same version reads it' do
    ledger = edited
    update = ledger.versions.last
    step = SpecTimelines.timeline(ledger, from: :first, to: ledger).last

    recorded = pairs(PaperTrailDiff.recorded_changes(update))

    expect(recorded).to eq(pairs(step.diff.attributes))
    expect(recorded.fetch('price')).to eq([BigDecimal('1.1'), BigDecimal('2.5')])
    expect(recorded.fetch('due')).to eq([Date.new(2026, 1, 2), Date.new(2026, 2, 2)])
    expect(recorded.fetch('seen_at')).to eq([Time.utc(2026, 1, 2, 3, 4, 5),
                                             Time.utc(2026, 3, 2, 3, 4, 5)])
    expect(recorded.fetch('opens_at').map { |time| time.strftime('%F %T') })
      .to eq(['2000-01-01 09:30:00', '2000-01-01 10:45:00'])
  end

  it 'casts the values a create recorded' do
    ledger = JsonLedger.create!(**first_values)

    recorded = pairs(PaperTrailDiff.recorded_changes(ledger.versions.first))

    expect(recorded.fetch('price')).to eq([nil, BigDecimal('1.1')])
    expect(recorded.fetch('due')).to eq([nil, Date.new(2026, 1, 2)])
    expect(recorded.fetch('seen_at')).to eq([nil, Time.utc(2026, 1, 2, 3, 4, 5)])
  end

  it 'credits every change to its version, with no write read as unversioned' do
    ledger = edited

    rows = PaperTrailDiff.analyze(ledger, activity: true, recorded_changes: true).change_rows
    changed = rows.select { |row| row.change == :changed }

    expect(rows.select(&:unversioned?)).to eq([])
    expect(changed.map(&:attribute))
      .to eq(%w[due meta opens_at price seen_at stage title])
    expect(changed.find { |row| row.attribute == 'due' }.to).to eq(Date.new(2026, 2, 2))
  end
end
