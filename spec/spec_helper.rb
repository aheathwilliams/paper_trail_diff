# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'simplecov'

coverage_name = ENV.fetch('PAPER_TRAIL_DIFF_COVERAGE', 'core')
SimpleCov.command_name(coverage_name)
SimpleCov.start do
  enable_coverage :branch
  add_filter '/spec/'
  if coverage_name == 'associations'
    minimum_coverage line: 95, branch: 80
  else
    add_filter '/activity_version_collector.rb'
    add_filter '/activity_event_snapshot_refresher.rb'
    add_filter '/activity_root_snapshot_refresher.rb'
    add_filter '/prepared_record_index.rb'
    minimum_coverage line: 85, branch: 60
  end
end

require 'paper_trail_diff'
