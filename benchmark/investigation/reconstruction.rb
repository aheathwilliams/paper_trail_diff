# frozen_string_literal: true

# Development-only probe: uses the association spec schema, always in memory.
# Run each scenario/size in a fresh process; no runtime library patches persist.
require 'bundler/setup'
require 'json'
require 'paper_trail'
require_relative '../../lib/paper_trail_diff'

scenarios = %w[scalar comments checkpoints belongs_to limited owner default_scope scoped
               through_has_many callback callable without_changes comments_without_changes
               polymorphic_belongs_to source_type_through]
scenario = ARGV.fetch(0)
size = Integer(ARGV.fetch(1))
abort 'invalid scenario or size' unless scenarios.include?(scenario) && size.positive?

ENV.delete('PAPER_TRAIL_DIFF_DATABASE_URL')
require_relative '../../spec/support/association_database'
polymorphic = %w[polymorphic_belongs_to source_type_through].include?(scenario)
require_relative '../../spec/support/source_type_database' if polymorphic

if scenario == 'default_scope'
  TrackedComment.class_eval { default_scope { where.not(body: 'hidden') } }
end
if scenario == 'scoped'
  TrackedArticle.has_many :scoped_comments, -> { where(reviewer_id: nil) },
                          class_name: 'TrackedComment', foreign_key: :article_id
end
TrackedArticle.after_initialize { TrackedTag.count } if scenario == 'callback'

# Polymorphic links from a holder: one to an author that is renamed, one that
# moves from a tag to another author.
polymorphic_roots = lambda do
  holder = SourceTypeHolder.create!(name: 'Before')
  author = SourceTypeAuthor.create!(name: 'Before')
  link = SourceTypeLink.create!(holder: holder, target: author)
  moved = SourceTypeLink.create!(holder: holder, target: SourceTypeTag.create!(name: 'Tag'))
  holder.update!(name: 'Middle')
  author.update!(name: 'Middle')
  moved.update!(target: SourceTypeAuthor.create!(name: 'Other'))
  link.update!(holder: holder)
  holder.update!(name: 'After')
  scenario == 'polymorphic_belongs_to' ? moved : holder
end
roots = Array.new(size) do
  next polymorphic_roots.call if polymorphic

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

counts = Hash.new(0)
reified_ids = Hash.new(0)
present_reified_ids = Hash.new(0)
# Where each reify comes from: the version's model and the innermost gem frame.
reify_origins = Hash.new(0)
record_reify_origin = lambda do |item_type|
  origin = caller_locations.find { |location| location.path.include?('/paper_trail_diff/') }
  reify_origins["#{item_type} #{origin.to_s.sub(%r{.*/lib/}, 'lib/')}"] += 1 if origin
end
PaperTrail::Version.prepend(Module.new do
  define_method(:reify) do |*args, **kwargs|
    counts[:reify] += 1
    record_reify_origin.call(item_type)
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
                'scoped' => :scoped_comments,
                'through_has_many' => :comments, 'polymorphic_belongs_to' => :target,
                'source_type_through' => :linked_authors }[scenario]
options = { since: Time.now.utc - 3600, limit: size, snapshots: true,
            associations: Array(association) }
# A path PT-AT reads is approximate and per record, so it takes both opt-ins.
if ENV['PTD_PROBE_ALLOW_EXPENSIVE'] == '1'
  options[:allow_expensive] = true
  options[:allow_approximate] = true
end
options[:historical_filter] = ->(state) { state.comments.exists? } if scenario == 'callable'
model = case scenario
        when 'through_has_many' then TrackedAuthor
        when 'source_type_through' then SourceTypeHolder
        # Each holder's other link changes in the window too, so name the roots.
        when 'polymorphic_belongs_to' then SourceTypeLink.where(id: roots.map(&:id))
        else TrackedArticle
        end
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
                 within: options[:since]..Time.now.utc
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
puts JSON.generate(
  scenario: scenario, roots: size, elapsed_ms: elapsed.round(3), counts: measured_counts,
  unique_reified_versions: reified_ids.length,
  repeated_reify_calls: reified_ids.values.sum { |count| count - 1 },
  repeated_present_reify_calls: present_reified_ids.values.sum { |count| count - 1 },
  reify_origins: reify_origins,
  statements: statements, query_origins: query_origins, error: error
)
