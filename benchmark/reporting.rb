# frozen_string_literal: true

require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'time'

scenarios = { 'many_roots' => [100, 500], 'retained_activity' => [100, 500],
              'long_history' => [1000, 5000], 'sparse_matches' => [100, 1000],
              'no_matches' => [100, 1000], 'limit_refusal' => [100, 1000] }
options = { samples: 3 }
OptionParser.new do |parser|
  parser.banner = 'Usage: bundle exec ruby benchmark/reporting.rb [options]'
  parser.on('--case NAME', scenarios.keys, 'Run only one scenario') do |value|
    options[:case] = value
  end
  parser.on('--size N', Integer, 'Override population/history size') do |value|
    options[:size] = value
  end
  parser.on('--samples N', Integer, 'Fresh processes per size (default: 3)') do |value|
    options[:samples] = value
  end
  parser.on('--output PATH', 'Write machine-readable results') { |value| options[:output] = value }
end.parse!
unless options[:samples].positive? && options.fetch(:size, 1).positive?
  abort 'samples and size must be positive'
end

samples = []
scenarios.each do |name, sizes|
  next if options[:case] && options[:case] != name

  (options[:size] ? [options[:size]] : sizes).each do |size|
    options[:samples].times do |index|
      warn "#{name} size=#{size} sample=#{index + 1}/#{options[:samples]}"
      worker = File.join(__dir__, 'reporting_worker.rb')
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, worker, name, size.to_s)
      abort "#{name} failed:\n#{stderr}\n#{stdout}" unless status.success?
      samples << JSON.parse(stdout).merge('sample' => index + 1)
    end
  end
end
revision, = Open3.capture2('git', 'rev-parse', 'HEAD', chdir: File.expand_path('..', __dir__))
payload = JSON.pretty_generate(measured_at: Time.now.utc.iso8601, revision: revision.strip,
                               platform: RUBY_PLATFORM, samples: samples)
options[:output] ? File.write(options[:output], "#{payload}\n") : puts(payload)
