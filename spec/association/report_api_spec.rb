# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :api_report_customers, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :api_report_orders, force: true do |table|
    table.string :status, null: false
    table.string :note
    table.integer :customer_id
    table.timestamps null: false
  end

  create_table :api_report_lines, force: true do |table|
    table.integer :order_id, null: false
    table.integer :quantity, null: false
    table.timestamps null: false
  end
end

class ApiReportCustomer < ActiveRecord::Base
  has_paper_trail
end

class ApiReportOrder < ActiveRecord::Base
  belongs_to :customer, class_name: 'ApiReportCustomer', optional: true
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
    ApiReportCustomer.delete_all
  end

  def identity(record) = PaperTrailDiff::Endpoint.identity(record)

  describe 'report(within:)', mutant_expression: 'PaperTrailDiff.report_window' do
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

    it 'reads from since: through now' do
      order = ApiReportOrder.create!(status: 'open')
      before = ApiReportOrder.create!(status: 'open')
      start = Time.now.utc
      order.update!(status: 'packed')

      report = PaperTrailDiff.report(ApiReportOrder.all, since: start, limit: 5)

      expect(report.analyses.keys).to eq([identity(order)])
      expect(report.analyses.fetch(identity(order)).window).to eq(start..)
      expect(before).to be_persisted
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

  describe 'limit:', mutant_expression: 'PaperTrailDiff::ScopedAnalysisBuilder#relation_limit' do
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

    it 'is required for a scope that is not a relation' do
      expect { PaperTrailDiff.report([], since: 1.day.ago) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /limit: is required/)
    end
  end

  describe 'selection through a record saved first after the change',
           mutant_expression: 'PaperTrailDiff::AssociationActivitySelection*' do
    def legacy(&block)
      PaperTrail.request(enabled: false, &block)
    end

    def selected(window, paths, **options)
      PaperTrailDiff.report(ApiReportOrder.all, within: window, limit: 5, associations: paths,
                                                **options).roots
    end

    it 'keeps a closed window once the record is first saved or deleted' do
      customer = ApiReportCustomer.create!(name: 'Acme')
      order = legacy { ApiReportOrder.create!(status: 'open', customer: customer) }
      start = Time.now.utc
      customer.update!(name: 'Acme Ltd')
      october = start..Time.now.utc

      expect(selected(october, [:customer])).to eq([order])
      order.update!(note: 'edited later')
      expect(selected(october, [:customer])).to eq([order])
      order.update!(customer: ApiReportCustomer.create!(name: 'Other'))
      expect(selected(october, [:customer])).to eq([order])
    end

    it 'keeps a record first saved onto another target in a save that deletes a legacy child' do
      customer, other = %w[Acme Other].map { |name| ApiReportCustomer.create!(name: name) }
      order, line = legacy do
        created = ApiReportOrder.create!(status: 'open', customer: customer)
        [created, created.lines.create!(quantity: 1)]
      end
      start = Time.now.utc
      customer.update!(name: 'Acme Ltd')
      october = start..Time.now.utc
      line.destroy!
      order.update!(customer: other)

      expect(selected(october, %w[customer lines])).to eq([order])
    end

    it 'keeps a record whose first version a version_scope leaves out' do
      customer, other = %w[Acme Other].map { |name| ApiReportCustomer.create!(name: name) }
      order = legacy { ApiReportOrder.create!(status: 'open', customer: customer) }
      start = Time.now.utc
      PaperTrail.request(whodunnit: 'alice') { customer.update!(name: 'Acme Ltd') }
      PaperTrail.request(whodunnit: 'bob') { order.update!(customer: other) }
      alice = ->(versions) { versions.where(whodunnit: 'alice') }

      expect(selected(start.., [:customer], version_scope: alice)).to eq([order])
      expect(selected(start.., [:customer],
                      version_scope: ->(versions) { versions.where(whodunnit: 'carol') }))
        .to eq([])
    end
  end

  describe 'Analysis#changed_attributes',
           mutant_expression: 'PaperTrailDiff::Analysis#changed_attributes' do
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

      expect(analysis.changed_attributes).to eq(%w[note status]).and be_frozen
      expect(analysis.diff.attributes.keys).to eq(%w[status])
    end

    it 'needs the activity timeline' do
      order = ApiReportOrder.create!(status: 'open')

      expect { PaperTrailDiff.analyze(order).changed_attributes }
        .to raise_error(PaperTrailDiff::ConfigurationError, /requires activity: true/)
    end
  end

  describe 'Analysis#changed_attributes with a requested belongs_to',
           mutant_expression: 'PaperTrailDiff::ActivityStep#changed_attributes' do
    it "names the key of a target the root's own update replaced" do
      old, new = %w[Old New].map { |name| ApiReportCustomer.create!(name: name) }
      order = ApiReportOrder.create!(status: 'open', customer: old)
      start = Time.now.utc
      old.update!(name: 'Old Ltd')
      order.update!(customer: new)

      analysis = PaperTrailDiff.analyze(order, within: start.., associations: [:customer],
                                               activity: true)

      expect(analysis.changed_attributes).to eq(%w[customer_id]).and be_frozen
      expect(analysis.activity_timeline.map(&:changed_attributes)).to eq([[], %w[customer_id]])
    end
  end

  describe 'ActivityStep#root_sources',
           mutant_expression: 'PaperTrailDiff::ActivityStep#root_sources' do
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

    it "names the root's update that gave it another target of a requested belongs_to" do
      old, new = %w[Old New].map { |name| ApiReportCustomer.create!(name: name) }
      order = ApiReportOrder.create!(status: 'open', customer: old)
      line = order.lines.create!(quantity: 1)
      start = Time.now.utc
      ApiReportOrder.transaction do
        line.destroy!
        order.update!(customer: new)
      end
      update = order.versions.last

      step = PaperTrailDiff.analyze(order, within: start.., associations: %i[customer lines],
                                           activity: true, group: :transaction)
                           .activity_timeline.reject(&:empty?).sole

      expect(step.root_sources.map(&:version_id)).to eq([update.id])
      expect(step.changed_attributes).to eq(%w[customer_id])
      customer_rows = step.change_rows.select { |row| row.association_path == ['customer'] }
      expect(customer_rows.map { |row| [row.change, row.source.version_id] }.uniq)
        .to eq([[:removed, update.id], [:added, update.id]])
    end

    it 'is empty for a save that changed only associated records' do
      order = ApiReportOrder.create!(status: 'open')
      line = order.lines.create!(quantity: 1)
      start = Time.now.utc
      line.update!(quantity: 2)

      expect(saved_steps(order, start).sole.root_sources).to eq([])
    end

    it 'names changes saved without a version once' do
      order = ApiReportOrder.create!(status: 'open')
      start = Time.now.utc
      order.update!(status: 'packed')
      order.update_columns(note: 'call first', status: 'held')

      steps = PaperTrailDiff.analyze(order, within: start.., activity: true,
                                            recorded_changes: true).activity_timeline

      step = steps.sole

      expect(step.change_rows.count(&:unversioned?)).to eq(2)
      expect(step.root_sources.map(&:kind)).to eq(%i[unversioned version])
      expect(step.root_sources).to be_frozen
    end
  end

  describe 'diagnose on a history YAML cannot load',
           history: :yaml,
           mutant_expression: 'PaperTrailDiff::HistoryDiagnostics#inspect_decoding' do
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
      expect(issue.message).to include('Tried to load unspecified class: ApiReportOrder::Unpermitted',
                                       'yaml_column_permitted_classes')
    end

    it 'reads nothing from a create, which stores no state, for a record with no other version' do
      order = ApiReportOrder.create!(status: 'open')

      expect(PaperTrailDiff.diagnose(order.versions.sole, order)).to be_ok
    end

    it "reads the record's next version that stores a state in place of a create" do
      order = ApiReportOrder.create!(status: 'open')
      order.update!(status: 'packed')
      order.update!(status: 'sent')
      create, first, second = order.versions.order(:id).to_a
      stored = "---\nstatus: !ruby/object:ApiReportOrder::Unpermitted {}\n"
      [first, second].each { |version| version.update_columns(object: stored) }

      report = PaperTrailDiff.diagnose(create, order)

      expect(report.errors.map { |issue| [issue.code, issue.version_id] })
        .to eq([[:disallowed_yaml_class, first.id]])
      expect(PaperTrailDiff.diagnose(create, first).errors.map(&:version_id)).to eq([first.id])
    end
  end
end

class ApiReportOrder
  Unpermitted = Class.new
end
