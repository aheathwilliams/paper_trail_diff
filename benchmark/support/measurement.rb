# frozen_string_literal: true

require 'objspace'

module ReportingBenchmark
  # Measures the report call; RSS high-water includes process setup and seeding.
  class Measurement
    attr_accessor :reifications

    def initialize
      @queries = 0
      @cached_queries = 0
      @sql_ms = 0.0
      @instantiated_records = 0
      @reifications = 0
    end

    def measure(&block)
      GC.start
      before = memory
      allocations = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = subscribe(&block)
      [result, finish(started, allocations, before)]
    end

    private

    def finish(started, allocations, before)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      allocated = GC.stat(:total_allocated_objects) - allocations
      after = memory
      GC.start
      retained_bytes = ObjectSpace.memsize_of_all - before.fetch(:ruby_bytes)
      readings(elapsed, allocated, before, after, retained_bytes)
    end

    def readings(elapsed, allocated, before, after, retained_bytes)
      { elapsed_ms: (elapsed * 1000).round(3), queries: @queries,
        cached_queries: @cached_queries, sql_ms: @sql_ms.round(3),
        instantiated_records: @instantiated_records, reifications: reifications,
        allocated_objects: allocated, retained_ruby_bytes: retained_bytes,
        rss_before_kib: before[:rss_kib], rss_after_kib: after[:rss_kib],
        process_peak_rss_kib: after[:peak_rss_kib] }
    end

    def memory
      status = File.read('/proc/self/status') if File.exist?('/proc/self/status')
      { ruby_bytes: ObjectSpace.memsize_of_all,
        rss_kib: status && status[/^VmRSS:\s+(\d+)/, 1]&.to_i,
        peak_rss_kib: status && status[/^VmHWM:\s+(\d+)/, 1]&.to_i }
    end

    def subscribe(&block)
      ActiveSupport::Notifications.subscribed(method(:query), 'sql.active_record',
                                              monotonic: true) do
        ActiveSupport::Notifications.subscribed(method(:instantiate),
                                                'instantiation.active_record', &block)
      end
    end

    def query(_name, started, finished, _id, payload)
      return if %w[SCHEMA TRANSACTION].include?(payload[:name])

      if payload[:cached]
        @cached_queries += 1
      else
        @queries += 1
        @sql_ms += (finished - started) * 1000
      end
    end

    def instantiate(_name, _started, _finished, _id, payload)
      @instantiated_records += payload.fetch(:record_count)
    end
  end
end
