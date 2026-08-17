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

# The gemfiles under gemfiles/ are generated from this Gemfile, and CI runs
# every job against them rather than against the Gemfile itself. So a change
# made only to the Gemfile is a change CI never executes: the jobs pass, but
# they pass on the old dependency. Regenerating and diffing turns that silent
# divergence into a failure that names the file to commit.
#
# Must run under the root Gemfile. Under a generated gemfile, Appraisal would
# read that as the base and write it back over itself.
desc 'Regenerate the Appraisal gemfiles and verify that they are committed'
task :verify_gemfiles do
  sh 'bundle', 'exec', 'appraisal', 'generate'
  sh 'git', 'diff', '--exit-code', '--', 'gemfiles'
end

# Everything that must be true before a release is tagged, in one command that
# fails loudly. The sequence is easy to get half-right by hand: a dirty tree
# tags something other than what was tested, an unpushed commit tags code CI
# never saw, a stale generated gemfile means CI tested different dependencies
# than the Gemfile names, and a heading left at `Unreleased` ships a version
# with no notes.
#
# It deliberately does not tag, push, or publish. Those stay explicit.
namespace :release do
  desc 'Check everything that must hold before tagging a release'
  task preflight: %i[default verify_gemfiles] do
    require_relative 'lib/paper_trail_diff/version'
    require_relative 'script/release_preflight'
    version = PaperTrailDiff::VERSION

    abort('Release preflight failed.') unless ReleasePreflight.new(version).call

    Rake::Task['build'].invoke
    puts "\nReady to release #{version}. Tag it explicitly:"
    puts "  git tag -a v#{version} -m 'paper_trail_diff #{version}'"
    puts "  git push origin v#{version}"
  end
end

task default: %i[spec rubocop typecheck]
