# frozen_string_literal: true

# Development-only probe: uses the association spec schema, always in memory.
# Run each scenario/size in a fresh process; no runtime library patches persist.
require 'bundler/setup'
require 'json'
require 'paper_trail'
require_relative '../../lib/paper_trail_diff'

scenarios = %w[scalar comments checkpoints belongs_to limited owner default_scope
               through_has_many callback callable without_changes comments_without_changes]
scenario = ARGV.fetch(0)
size = Integer(ARGV.fetch(1))
abort 'invalid scenario or size' unless scenarios.include?(scenario) && size.positive?
prepared_through = ARGV[2] == 'prepared-through'
if ARGV[2] && !(prepared_through && scenario == 'through_has_many')
  abort 'prepared-through is only valid for through_has_many'
end

ENV.delete('PAPER_TRAIL_DIFF_DATABASE_URL')
require_relative '../../spec/support/association_database'

if scenario == 'default_scope'
  TrackedComment.class_eval { default_scope { where.not(body: 'hidden') } }
end
TrackedArticle.after_initialize { TrackedTag.count } if scenario == 'callback'

roots = Array.new(size) do
  author = TrackedAuthor.create!(name: 'Author')
  article = TrackedArticle.create!(title: 'Before', author: author)
  comment = article.comments.create!(body: 'Before')
  article.comments.create!(body: 'Another')
  article.update!(title: 'Middle')
  comment.update!(body: 'Middle')
  article.update!(title: 'After')
  scenario == 'through_has_many' ? author : article
end
roots.each { |author| author.update!(name: 'After') } if scenario == 'through_has_many'
PaperTrail::Version.update_all(object_changes: nil) if scenario.end_with?('without_changes')
captured_at = Time.now
Time.define_singleton_method(:now) { captured_at }
# Investigate the existing indexed resolver, without changing production code.
experimental = Module.new { define_method(:deferred_macro?) { |_reflection| false } }
PaperTrailDiff::PreparedHistoryLoader.prepend(experimental) if prepared_through

counts = Hash.new(0)
reified_ids = Hash.new(0)
present_reified_ids = Hash.new(0)
PaperTrail::Version.prepend(Module.new do
  define_method(:reify) do |*args, **kwargs|
    counts[:reify] += 1
    reified_ids[[item_type, id]] += 1
    present_reified_ids[[item_type, id]] += 1 if object
    super(*args, **kwargs)
  end
end)
PaperTrailDiff::PreparedRecordState.prepend(Module.new do
  define_method(:instantiate) do
    counts[:prepared_instances] += 1
    super()
  end
end)
PaperTrailDiff::HistoricalAssociationReifier.prepend(Module.new do
  define_method(:reify) do |record, reflections|
    counts[:fallback_reflections] += reflections.length
    super(record, reflections)
  end
end)
# Observe construction without adding callbacks that would disable the plain-state path.
construction_trace = TracePoint.new(:call) do |event|
  if event.defined_class == ActiveRecord::Core &&
     %i[initialize init_with_attributes].include?(event.method_id)
    counts[:model_initializations] += 1
  end
end

association = { 'comments' => :comments, 'comments_without_changes' => :comments,
                'checkpoints' => :comments, 'belongs_to' => :author,
                'limited' => :limited_comments,
                'owner' => :owner_comments, 'default_scope' => :comments,
                'through_has_many' => :comments }[scenario]
options = { since: Time.now.utc - 3600, limit: size, snapshots: true,
            associations: Array(association) }
options[:allow_expensive] = true if ENV['PTD_PROBE_ALLOW_EXPENSIVE'] == '1'
options[:historical_filter] = ->(state) { state.comments.exists? } if scenario == 'callable'
model = scenario == 'through_has_many' ? TrackedAuthor : TrackedArticle
statements = Hash.new(0)
query_origins = Hash.new(0)
callback = lambda do |*args|
  payload = args.last
  next if %w[SCHEMA TRANSACTION].include?(payload[:name])

  counts[payload[:cached] ? :cached_queries : :queries] += 1
  statements[payload[:name]] += 1
  origin = caller_locations.find do |location|
    location.path.include?('/paper_trail_diff/') || location.path.include?('association_tracking')
  end
  query_origins[origin.to_s.sub(%r{.*/lib/}, 'lib/')] += 1 if origin
end
result = nil
error = nil
GC.start
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
begin
  construction_trace.enable
  ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
    result = ActiveRecord::Base.uncached do
      if scenario == 'checkpoints'
        PaperTrailDiff.analyze_scope(
          model, limit: size, associations: [:comments],
                 within: options[:since]..Time.now.utc, close_on: :current
        )
      else
        PaperTrailDiff.report(model, **options)
      end
    end
  end
rescue PaperTrailDiff::Error, ActiveRecord::ActiveRecordError => e
  error = { type: e.class.name, message: e.message }
ensure
  construction_trace.disable
end
elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
if result && result.roots.length != size
  abort "#{scenario}: expected #{size} roots, got #{result.roots.length}"
end
measured_counts = counts.dup
equal = nil
if prepared_through && result
  experimental.send(:remove_method, :deferred_macro?)
  # Snapshot counters before this untimed check against the ordinary fallback.
  measured_ids = reified_ids.dup
  measured_present_ids = present_reified_ids.dup
  expected = PaperTrailDiff.report(model, **options)
  serialize = lambda { |report|
    report.analyses.transform_values do |analysis|
      analysis.to_h(snapshots: true)
    end
  }
  equal = serialize.call(result) == serialize.call(expected)
  reified_ids = measured_ids
  present_reified_ids = measured_present_ids
end
puts JSON.generate(
  scenario: scenario, roots: size, elapsed_ms: elapsed.round(3), counts: measured_counts,
  unique_reified_versions: reified_ids.length,
  repeated_reify_calls: reified_ids.values.sum { |count| count - 1 },
  repeated_present_reify_calls: present_reified_ids.values.sum { |count| count - 1 },
  statements: statements, query_origins: query_origins, error: error,
  prepared_through: prepared_through, equivalent_output: equal
)
