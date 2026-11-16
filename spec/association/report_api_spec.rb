# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :api_report_orders, force: true do |table|
    table.string :status, null: false
    table.string :note
    table.timestamps null: false
  end

  create_table :api_report_lines, force: true do |table|
    table.integer :order_id, null: false
    table.integer :quantity, null: false
    table.timestamps null: false
  end
end

class ApiReportOrder < ActiveRecord::Base
  has_many :lines, class_name: 'ApiReportLine', foreign_key: :order_id, inverse_of: :order
  has_paper_trail
end

class ApiReportLine < ActiveRecord::Base
  belongs_to :order, class_name: 'ApiReportOrder', inverse_of: :lines
  has_paper_trail
end

# What a report page reaches for: a closed window, the page's own limit as
# its ceiling, the root's changed fields, and the root's own event in a save.
RSpec.describe 'Report API for a reporting page' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    ApiReportLine.delete_all
    ApiReportOrder.delete_all
  end

  def identity(record) = PaperTrailDiff::Endpoint.identity(record)

  describe 'report(within:)' do
    it 'selects a root whose only change in a closed window was to an association' do
      order = ApiReportOrder.create!(status: 'open')
      line = order.lines.create!(quantity: 1)
      untouched = ApiReportOrder.create!(status: 'open')
      start = Time.now.utc
      line.update!(quantity: 2)
      finish = Time.now.utc
      untouched.update!(status: 'packed')

      report = PaperTrailDiff.report(ApiReportOrder.all, within: start..finish, limit: 5,
                                                         associations: [:lines])

      expect(report.analyses.keys).to eq([identity(order)])
      expect(report.analyses.fetch(identity(order)).window).to eq(start..finish)
    end

    it 'leaves out changes after the window ends' do
      order = ApiReportOrder.create!(status: 'open')
      start = Time.now.utc
      order.update!(status: 'packed')
      finish = Time.now.utc
      order.update!(status: 'shipped')

      analysis = PaperTrailDiff.report(ApiReportOrder.all, within: start..finish, limit: 5)
                               .analyses.fetch(identity(order))

      expect(analysis.diff.attributes.fetch('status').to_h).to eq(from: 'open', to: 'packed')
    end

    it 'takes one of since: or within:' do
      expect { PaperTrailDiff.report(ApiReportOrder.all, limit: 5) }
        .to raise_error(PaperTrailDiff::InvalidTimeRangeError, /one of `since:` or `within:`/)
      expect do
        PaperTrailDiff.report(ApiReportOrder.all, since: Time.now, within: Time.now.., limit: 5)
      end.to raise_error(PaperTrailDiff::InvalidTimeRangeError, /one of `since:` or `within:`/)
    end

    it 'points a range given as since: to within:' do
      expect { PaperTrailDiff.report(ApiReportOrder.all, since: Time.now.., limit: 5) }
        .to raise_error(PaperTrailDiff::InvalidTimeRangeError, /pass it as `within:`\z/)
    end
  end

  describe 'limit:' do
    it "defaults to the relation's own limit" do
      orders = Array.new(3) { ApiReportOrder.create!(status: 'open') }

      report = PaperTrailDiff.report(ApiReportOrder.order(:id).limit(2), since: 1.day.ago)

      expect(report.roots).to eq(orders.first(2))
      expect(report.total).to eq(3)
    end

    it 'is required for a relation without a limit' do
      expect { PaperTrailDiff.report(ApiReportOrder.all, since: 1.day.ago) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /limit: is required/)
      expect { PaperTrailDiff.analyze_scope(ApiReportOrder, within: 1.day.ago..) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /limit: is required/)
    end
  end

  describe 'Analysis#changed_attributes' do
    it "names the root's own fields that changed, even those changed back" do
      order = ApiReportOrder.create!(status: 'open')
      line = order.lines.create!(quantity: 1)
      start = Time.now.utc
      order.update!(note: 'call first')
      order.update!(status: 'packed')
      order.update!(note: nil)
      line.update!(quantity: 2)

      analysis = PaperTrailDiff.analyze(order, within: start.., associations: [:lines],
                                               activity: true)

      expect(analysis.changed_attributes).to eq(%w[note status])
      expect(analysis.diff.attributes.keys).to eq(%w[status])
    end

    it 'needs the activity timeline' do
      order = ApiReportOrder.create!(status: 'open')

      expect { PaperTrailDiff.analyze(order).changed_attributes }
        .to raise_error(PaperTrailDiff::ConfigurationError, /requires activity: true/)
    end
  end

  describe 'ActivityStep#root_sources' do
    def saved_steps(order, start)
      PaperTrailDiff.analyze(order, within: start.., associations: [:lines], activity: true,
                                    group: :transaction).activity_timeline.reject(&:empty?)
    end

    it "names the root's own event when an association's event opened the save" do
      order = ApiReportOrder.create!(status: 'open')
      line = order.lines.create!(quantity: 1)
      start = Time.now.utc
      ApiReportOrder.transaction do
        line.destroy!
        order.update!(status: 'packed')
      end

      step = saved_steps(order, start).sole

      expect(step.source_boundary.item_type).to eq('ApiReportLine')
      expect(step.root_sources.map { |source| [source.item_type, source.event] })
        .to eq([%w[ApiReportOrder update]])
    end

    it 'is empty for a save that changed only associated records' do
      order = ApiReportOrder.create!(status: 'open')
      line = order.lines.create!(quantity: 1)
      start = Time.now.utc
      line.update!(quantity: 2)

      expect(saved_steps(order, start).sole.root_sources).to eq([])
    end
  end

  describe 'diagnose on a history YAML cannot load', history: :yaml do
    it 'names the class to permit' do
      order = ApiReportOrder.create!(status: 'open')
      order.update!(status: 'packed')
      version = order.versions.last
      stored = "---\nstatus: !ruby/object:ApiReportOrder::Unpermitted {}\n"
      version.update_columns(object: stored)

      report = PaperTrailDiff.diagnose(version, order)

      expect(report).not_to be_ok
      issue = report.errors.sole
      expect(issue.code).to eq(:disallowed_yaml_class)
      expect(issue.version_id).to eq(version.id)
      expect(issue.message).to include('ApiReportOrder::Unpermitted',
                                       'yaml_column_permitted_classes')
    end
  end
end

class ApiReportOrder
  Unpermitted = Class.new
end
