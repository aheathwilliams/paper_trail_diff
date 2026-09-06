# frozen_string_literal: true

require 'bundler/setup'
require 'json'
require_relative 'support/workload'
require_relative 'support/measurement'

workload = ReportingBenchmark::Workload.new(ARGV.fetch(0), Integer(ARGV.fetch(1)))
workload.prepare
measurement = ReportingBenchmark::Measurement.new
PaperTrail::Version.prepend(Module.new do
  define_method(:reify) do |*args, **kwargs|
    measurement.reifications += 1
    super(*args, **kwargs)
  end
end)

result, readings = measurement.measure do
  ActiveRecord::Base.uncached { workload.call }
rescue PaperTrailDiff::BatchLimitExceededError => e
  raise unless workload.name == 'limit_refusal'

  e
end
outcome = if result.is_a?(Exception)
            { outcome: result.class.name }
          else
            if workload.name == 'limit_refusal'
              raise 'expected the safety ceiling to refuse the report'
            end
            unless result.roots.length == workload.expected_roots
              raise 'unexpected selected population'
            end

            { outcome: 'ok', selected_roots: result.roots.length,
              unreachable: result.unreachable.length }
          end
puts JSON.generate(readings.merge(outcome).merge(
                     scenario: workload.name, size: workload.size, roots: workload.root_count,
                     versions: PaperTrail::Version.count, limit: workload.limit,
                     ruby: RUBY_DESCRIPTION, active_record: ActiveRecord.version.to_s,
                     paper_trail: PaperTrail::VERSION::STRING, gem_version: PaperTrailDiff::VERSION,
                     sqlite: ActiveRecord::Base.connection.select_value('SELECT sqlite_version()')
                   ))
