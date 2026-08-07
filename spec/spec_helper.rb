# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'simplecov'

SimpleCov.command_name(ENV.fetch('PAPER_TRAIL_DIFF_COVERAGE', 'core'))
SimpleCov.start do
  enable_coverage :branch
  add_filter '/spec/'
end

require 'paper_trail_diff'
