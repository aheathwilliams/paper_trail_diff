# frozen_string_literal: true

require 'bundler/setup'
require 'json'
require 'date'
require_relative '../support/workload'
require_relative 'scalar_snapshot_spike'

ReportingBenchmark::Workload.new('many_roots', 1).prepare
ActiveRecord.yaml_column_permitted_classes = [Symbol, Time, Date, BigDecimal]
ActiveRecord::Schema.define do
  change_table :benchmark_articles do |table|
    table.string :type
    table.integer :phase
    table.decimal :amount, precision: 10, scale: 2
    table.date :published_on
    table.boolean :visible
    table.json :config
    table.text :settings
    table.string :unrecorded, default: 'column default'
  end
end
BenchmarkArticle.reset_column_information
BenchmarkArticle.enum :phase, { draft: 0, reviewed: 1 }
BenchmarkArticle.serialize :settings, coder: JSON
Object.const_set(:SpikeSpecialArticle, Class.new(BenchmarkArticle))
Object.const_set(:SpikeCallbackArticle, Class.new(BenchmarkArticle))
SpikeCallbackArticle.after_initialize { self.unrecorded = 'callback value' }
Object.const_set(:SpikeScopedArticle, Class.new(BenchmarkArticle))
SpikeScopedArticle.class_eval { default_scope { where(unrecorded: 'scope value') } }

adapter = PaperTrailDiff::PaperTrailAdapter.new(associations: [], ignore: ['updated_at'])
normalizer = adapter.instance_variable_get(:@normalizer)
cases = [BenchmarkArticle, SpikeSpecialArticle, SpikeCallbackArticle, SpikeScopedArticle]
results = cases.map do |model|
  record = model.create!(title: 'Before', phase: :reviewed, amount: '12.34',
                         published_on: Date.new(2026, 1, 2), visible: true,
                         config: { 'list' => [1, nil] }, settings: { 'mode' => 'dark' })
  record.update!(title: 'After')
  version = record.versions.order(:id).last
  stored = version.object_deserialized.except('unrecorded')
  version.update_column(:object, PaperTrail.serializer.dump(stored))
  expected = normalizer.call(version.reify(dup: true), reifier: nil)
  actual = ScalarSnapshotSpike.snapshot(version, normalizer)
  differing = expected.attributes.keys.union(actual.attributes.keys).reject do |key|
    expected.attributes[key] == actual.attributes[key]
  end
  { model: model.name, equal: actual.to_h == expected.to_h,
    different_attributes: differing, expected: expected.attributes.slice(*differing),
    actual: actual.attributes.slice(*differing) }
end
puts JSON.pretty_generate(results)
