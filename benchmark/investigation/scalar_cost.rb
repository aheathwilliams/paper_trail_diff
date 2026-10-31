# frozen_string_literal: true

require 'bundler/setup'
require 'json'
require_relative '../support/workload'
require_relative '../support/measurement'
require_relative 'scalar_snapshot_spike'

mode = ARGV.fetch(0)
size = Integer(ARGV.fetch(1))
abort 'use baseline or direct' unless %w[baseline direct].include?(mode)
workload = ReportingBenchmark::Workload.new('many_roots', size)
workload.prepare
# Keep current-boundary metadata identical for the parity check after timing.
# Prepended, so it runs ahead of the workload's monotonic clock, which would
# otherwise move each reading on by a microsecond.
captured_at = Time.now
Time.singleton_class.prepend(Module.new { define_method(:now) { captured_at } })
PaperTrailDiff::HistoricalSnapshotStore.prepend(ScalarSnapshotSpike)
ScalarSnapshotSpike.enabled = mode == 'direct'
measurement = ReportingBenchmark::Measurement.new
PaperTrail::Version.prepend(Module.new do
  define_method(:reify) do |*args, **kwargs|
    measurement.reifications += 1
    super(*args, **kwargs)
  end
end)
model_initializations = 0
BenchmarkArticle.after_initialize { model_initializations += 1 }
result, readings = measurement.measure do
  ActiveRecord::Base.uncached { workload.call }
end
readings[:model_initializations] = model_initializations
ScalarSnapshotSpike.enabled = false
expected = workload.call
serialize = lambda { |report|
  report.analyses.transform_values do |analysis|
    analysis.to_h(snapshots: true)
  end
}
equal = serialize.call(result) == serialize.call(expected)
unless equal
  warn JSON.pretty_generate(actual: serialize.call(result).values.first,
                            expected: serialize.call(expected).values.first)
  abort 'direct snapshots changed the output'
end
puts JSON.generate(readings.merge(mode: mode, size: size, equivalent_output: equal))
