# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'fileutils'
require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RSpec::Core::RakeTask.new(:spec_core) do |task|
  task.pattern = 'spec/{unit,integration}/**/*_spec.rb'
end

RSpec::Core::RakeTask.new(:spec_associations) do |task|
  task.pattern = 'spec/association/**/*_spec.rb'
end

desc 'Run all specs in isolated core and association-tracking processes'
task spec: %i[spec_core spec_associations]

RuboCop::RakeTask.new(:rubocop)

desc 'Generate RBS signatures from inline comments'
task :rbs do
  FileUtils.rm_rf('sig/generated')
  FileUtils.mkdir_p('sig/generated')
  sh 'bundle', 'exec', 'rbs-inline', '--output', 'sig/generated', 'lib'
end

desc 'Regenerate signatures and verify that they are committed'
task verify_signatures: :rbs do
  sh 'git', 'diff', '--exit-code', '--', 'sig/generated'
end

desc 'Verify generated signatures and run Steep'
task typecheck: :verify_signatures do
  sh 'bundle', 'exec', 'steep', 'check'
end

task default: %i[spec rubocop typecheck]
