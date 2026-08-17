# frozen_string_literal: true

require 'English'
require 'fileutils'
require 'tmpdir'

# Loads the library under the oldest Ruby the gemspec claims to support.
#
# The gate runs on whatever Ruby the developer happens to have, so a constant
# introduced after the declared floor passes everything locally and fails only
# in CI -- `Data.define` did exactly that, resolved at load time and breaking
# every Ruby 3.1 job while a Ruby 4.0 machine saw a clean run. RuboCop does not
# cover it either: `TargetRubyVersion` constrains syntax, and this is a constant.
#
# The load needs no gems. Only two external requires exist, so both are stubbed
# and the whole library is loaded from source -- which is enough, because the
# failure being hunted happens while class bodies are evaluated.
#
# Missing floor Ruby is a skip, not a failure. The check is here to shorten the
# feedback loop before a push; CI still runs the real matrix, so refusing to
# work without a second Ruby installed would cost more than it protects.
class RubyFloorCheck
  # Requires that lib/ makes of the outside world, and the least each can be.
  STUBS = {
    'paper_trail.rb' => "module PaperTrail; end\n",
    'active_support/notifications.rb' => <<~RUBY
      module ActiveSupport
        module Notifications
          def self.instrument(*_args, **_kwargs)
            yield if block_given?
          end

          def self.subscribe(*_args); end
        end
      end
    RUBY
  }.freeze

  # Everything that touches the world, isolated so the logic can be tested
  # without a second Ruby installed.
  class Facts
    def declared_floor(gemspec_path)
      File.read(gemspec_path)[/required_ruby_version\s*=\s*['"][^\d]*([\d.]+)/, 1]
    end

    def current_version
      RUBY_VERSION
    end

    def floor_available?(floor)
      system('mise', 'x', "ruby@#{floor}", '--', 'ruby', '-v',
             out: File::NULL, err: File::NULL)
    end

    # Returns [ok, output]. Runs the load in a subprocess so a NameError in a
    # class body is reported rather than taking this process down with it.
    def load_under(floor, load_paths, current:)
      includes = load_paths.flat_map { |path| ['-I', path] }
      command = current ? ['ruby'] : ['mise', 'x', "ruby@#{floor}", '--', 'ruby']
      output = IO.popen(
        unbundled_env, [*command, *includes, '-e', 'require "paper_trail_diff"'],
        err: %i[child out], &:read
      )
      [$CHILD_STATUS.success?, output.to_s]
    end

    private

    # The load needs no gems, so the surrounding bundle is not merely
    # unnecessary but wrong: it was resolved for this Ruby, and its native
    # extensions are built against an ABI the floor Ruby does not share. Left in
    # place it reports every one of them as broken and the check fails for a
    # reason that has nothing to do with the code.
    def unbundled_env
      %w[
        BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN_PATH BUNDLER_VERSION BUNDLER_SETUP
        RUBYOPT RUBYLIB GEM_HOME GEM_PATH
      ].to_h { |name| [name, nil] }
    end
  end

  def initialize(gemspec_path, facts: Facts.new, output: $stdout)
    @gemspec_path = gemspec_path
    @facts = facts
    @output = output
  end

  # True when the library loaded, or when there was nothing to load it with.
  # A missing floor Ruby is reported and passed over rather than failed, so the
  # gate still runs for anyone who has only one Ruby installed.
  def call
    floor = @facts.declared_floor(@gemspec_path)
    if floor.nil?
      report_unknown_floor
      return true
    end
    return run(floor, current: true) if current_is_floor?(floor)
    return run(floor, current: false) if @facts.floor_available?(floor)

    report_skip(floor)
    true
  end

  private

  def current_is_floor?(floor)
    @facts.current_version.start_with?("#{floor}.")
  end

  def run(floor, current:)
    Dir.mktmpdir('paper_trail_diff_floor') do |stub_dir|
      write_stubs(stub_dir)
      loaded, output = @facts.load_under(floor, [stub_dir, 'lib'], current: current)
      loaded ? report_pass(floor, current) : report_failure(floor, output)
      loaded
    end
  end

  def write_stubs(stub_dir)
    STUBS.each do |path, source|
      target = File.join(stub_dir, path)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, source)
    end
  end

  def report_pass(floor, current)
    where = current ? 'this Ruby' : "Ruby #{floor}"
    @output.puts("Ruby floor: lib/ loads under #{where}.")
  end

  def report_failure(floor, output)
    @output.puts("Ruby floor: lib/ does not load under Ruby #{floor}.")
    @output.puts(output.to_s.lines.first(15).join.rstrip)
    @output.puts("The gemspec claims Ruby >= #{floor}. Either avoid the construct " \
                 'above or raise required_ruby_version.')
  end

  def report_skip(floor)
    @output.puts("Ruby floor: skipped, no Ruby #{floor} available " \
                 "(install one with `mise install ruby@#{floor}` to check before CI does).")
  end

  def report_unknown_floor
    @output.puts('Ruby floor: skipped, the gemspec declares no required_ruby_version.')
  end
end
