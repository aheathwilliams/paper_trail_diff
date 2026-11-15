# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :grouped_report_orders, force: true do |table|
    table.string :status, null: false
    table.timestamps null: false
  end

  create_table :grouped_report_lines, force: true do |table|
    table.integer :order_id, null: false
    table.integer :quantity, null: false
    table.timestamps null: false
  end
end

class GroupedReportOrder < ActiveRecord::Base
  has_many :lines, class_name: 'GroupedReportLine', foreign_key: :order_id, inverse_of: :order
  has_paper_trail
end

class GroupedReportLine < ActiveRecord::Base
  belongs_to :order, class_name: 'GroupedReportOrder', inverse_of: :lines
  has_paper_trail
end

# A report with associations reports each saved transaction as one step, as
# `group: :transaction` does, unless `group: nil` asks for every version alone.
RSpec.describe 'Report grouping by default' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    GroupedReportLine.delete_all
    GroupedReportOrder.delete_all
  end

  # One save that changes the order and its line together.
  def order_saved_with_line
    order = GroupedReportOrder.create!(status: 'open')
    line = order.lines.create!(quantity: 1)
    start = Time.now.utc
    GroupedReportOrder.transaction do
      order.update!(status: 'packed')
      line.update!(quantity: 2)
    end
    [order, start]
  end

  def steps(order, start, **options)
    PaperTrailDiff.report(GroupedReportOrder.all, since: start, limit: 5, **options)
                  .analyses.fetch(PaperTrailDiff::Endpoint.identity(order))
                  .activity_timeline.reject(&:empty?)
  end

  it 'reports one save of the order and its line as one step' do
    order, start = order_saved_with_line

    saved = steps(order, start, associations: [:lines])

    expect(saved.length).to eq(1)
    expect(saved.first.sources.map(&:item_type)).to eq(%w[GroupedReportOrder GroupedReportLine])
  end

  it 'reports the same step as an explicit transaction group' do
    order, start = order_saved_with_line

    explicit = steps(order, start, associations: [:lines], group: :transaction)

    summary = ->(list) { list.map { |step| [step.diff.to_h, step.sources.map(&:version_id)] } }

    expect(summary.call(steps(order, start, associations: [:lines]))).to eq(summary.call(explicit))
  end

  it 'reports each version alone when grouping is turned off' do
    order, start = order_saved_with_line

    expect(steps(order, start, associations: [:lines], group: nil).length).to eq(2)
  end

  it 'does not group a report without associations' do
    order = GroupedReportOrder.create!(status: 'open')
    start = Time.now.utc
    GroupedReportOrder.transaction do
      order.update!(status: 'packed')
      order.update!(status: 'shipped')
    end

    expect(steps(order, start).length).to eq(2)
  end
end
