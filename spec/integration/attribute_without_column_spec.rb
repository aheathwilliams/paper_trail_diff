# frozen_string_literal: true

require_relative '../support/core_database'

ActiveRecord::Schema.define do
  create_table :formed_orders, force: true do |table|
    table.string :state
    table.timestamps null: false
  end
end

# Form fields, which no column stores; PaperTrail writes them all the same.
class FormedOrder < ActiveRecord::Base
  attribute :note, :string
  attribute :notify, :boolean, default: false
  has_paper_trail
end

RSpec.describe 'An attribute declared without a column' do
  before do
    PaperTrail::Version.delete_all
    FormedOrder.delete_all
  end

  let!(:started) { Time.current - 1 }

  def history
    PaperTrail.request(whodunnit: 'alice') do
      order = FormedOrder.create!(state: 'new')
      order.update!(state: 'paid', note: 'customer called', notify: true)
    end
    PaperTrail.request(whodunnit: 'bob') { FormedOrder.first.update!(state: 'shipped') }
    FormedOrder.first
  end

  it 'is compared as no row holds it: not at all' do
    order = history

    expect(PaperTrailDiff.compare(order.versions.second, order).attributes.keys).to eq(['state'])
    expect(PaperTrailDiff.recorded_changes(order.versions.second).keys).to eq(['state'])
  end

  it 'adds no fields to a created record, and no unversioned rows' do
    history
    report = PaperTrailDiff.report(FormedOrder.all, since: started, limit: 5,
                                                    recorded_changes: true, snapshots: true)
    rows = report.change_rows.values.first

    expect(rows.filter_map(&:attribute)).not_to include('note', 'notify')
    expect(rows.select(&:unversioned?)).to be_empty
  end

  it 'is refused by historical_filter, as where refuses it' do
    history

    expect do
      PaperTrailDiff.report(FormedOrder.all, since: started, limit: 5,
                                             historical_filter: { notify: true })
    end
      .to raise_error(PaperTrailDiff::ConfigurationError, /unknown historical attributes: notify/)
  end
end
