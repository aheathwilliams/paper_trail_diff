# frozen_string_literal: true

require 'open3'

# Steep can recover from an internal exception and still exit successfully.
# Such a run did not finish checking every expression and must fail the gate.
module SteepCheck
  module_function

  def call
    stdout, stderr, status = Open3.capture3('bundle', 'exec', 'steep', 'check')
    $stdout.print(stdout)
    $stderr.print(stderr)
    successful?(status.exitstatus, stdout + stderr)
  end

  def successful?(exitstatus, output)
    (exitstatus || -1).zero? && !output.match?(/FATAL:|Unexpected error:/)
  end
end
