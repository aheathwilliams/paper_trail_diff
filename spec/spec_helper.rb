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
    minimum_coverage line: 90, branch: 65
  end
end

require 'paper_trail_diff'
