# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'fileutils'
require 'rbconfig'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'

task :core_coverage do
  ENV['PAPER_TRAIL_DIFF_COVERAGE'] = 'core'
end

task :association_coverage do
  ENV['PAPER_TRAIL_DIFF_COVERAGE'] = 'associations'
end

RSpec::Core::RakeTask.new(:spec_core) do |task|
  task.pattern = 'spec/{unit,integration}/**/*_spec.rb'
end
Rake::Task[:spec_core].enhance([:core_coverage])

RSpec::Core::RakeTask.new(:spec_associations) do |task|
  task.pattern = 'spec/{unit,association}/**/*_spec.rb'
  task.exclude_pattern = 'spec/unit/loading_spec.rb'
end
Rake::Task[:spec_associations].enhance([:association_coverage])

desc 'Run all specs in isolated core and association-tracking processes'
task spec: %i[spec_core spec_associations]

RuboCop::RakeTask.new(:rubocop)

desc 'Generate RBS signatures from inline comments'
task :rbs do
  FileUtils.rm_rf('sig/generated')
  FileUtils.mkdir_p('sig/generated')
  sh 'bundle', 'exec', 'rbs-inline', '--output', 'sig/generated', 'lib'
  sh RbConfig.ruby, 'script/normalize_generated_rbs', 'sig/generated'
end

desc 'Regenerate signatures and verify that they are committed'
task verify_signatures: :rbs do
  sh 'git', 'diff', '--exit-code', '--', 'sig/generated'
end

desc 'Verify generated signatures and run Steep'
task typecheck: :verify_signatures do
  sh 'bundle', 'exec', 'steep', 'check'
end

# Everything that must be true before a release is tagged, in one command that
# fails loudly. The sequence is easy to get half-right by hand: a dirty tree
# tags something other than what was tested, an unpushed commit tags code CI
# never saw, and a heading left at `Unreleased` ships a version with no notes.
#
# It deliberately does not tag, push, or publish. Those stay explicit.
namespace :release do
  desc 'Check everything that must hold before tagging a release'
  task preflight: :default do
    require_relative 'lib/paper_trail_diff/version'
    version = PaperTrailDiff::VERSION

    ReleasePreflight.new(version).call
    Rake::Task['build'].invoke

    puts "\nReady to release #{version}. Tag it explicitly:"
    puts "  git tag -a v#{version} -m 'paper_trail_diff #{version}'"
    puts "  git push origin v#{version}"
  end
end

# Each check states what it wants and why, so a failure explains itself rather
# than leaving the reader to reconstruct the rule.
class ReleasePreflight
  def initialize(version)
    @version = version
    @failures = []
  end

  def call
    clean_working_tree
    synchronised_with_origin
    unused_tag
    changelog_section
    unpublished_version
    report
  end

  private

  attr_reader :version

  def clean_working_tree
    return if `git status --porcelain`.strip.empty?

    fail_with('the working tree has uncommitted changes',
              'a tag would name a commit that differs from what was tested')
  end

  def synchronised_with_origin
    system('git', 'fetch', '--quiet', 'origin', exception: false)
    local = `git rev-parse HEAD`.strip
    remote = `git rev-parse @{u}`.strip
    return if local == remote && !local.empty?

    fail_with('HEAD does not match its upstream branch',
              'CI has not run against the commit the tag would point at')
  end

  def unused_tag
    return unless system("git rev-parse -q --verify refs/tags/v#{version} > /dev/null")

    fail_with("tag v#{version} already exists",
              'a published tag must never be moved to include later work')
  end

  def changelog_section
    changelog = File.read('CHANGELOG.md')
    return if changelog.match?(/^## \[#{Regexp.escape(version)}\] - \d{4}-\d{2}-\d{2}$/)

    fail_with("CHANGELOG.md has no dated section for #{version}",
              'the `Unreleased` heading still needs replacing with the version and date')
  end

  # Network trouble is not evidence either way, so it is reported as unknown
  # rather than silently treated as "not published".
  def unpublished_version
    require 'json'
    require 'net/http'

    uri = URI('https://rubygems.org/api/v1/versions/paper_trail_diff.json')
    published = JSON.parse(Net::HTTP.get(uri)).map { |release| release['number'] }
    return unless published.include?(version)

    fail_with("#{version} is already published on RubyGems",
              'a released version can never be replaced, only superseded')
  rescue StandardError => e
    warn "  ? could not reach RubyGems to check for #{version} (#{e.class})"
  end

  def fail_with(problem, reason)
    @failures << "  x #{problem}\n    #{reason}"
  end

  def report
    return puts("Release preflight passed for #{version}.") if @failures.empty?

    abort(['Release preflight failed:', *@failures].join("\n"))
  end
end

task default: %i[spec rubocop typecheck]
