# frozen_string_literal: true

require 'json'
require 'net/http'

# Everything that must hold before a release is tagged. Each check states what
# it wants and why, so a failure explains itself rather than leaving the reader
# to reconstruct the rule.
#
# It reports; it never tags, pushes, or publishes.
class ReleasePreflight
  # Everything the checks need to know about the world, in one place so the
  # checks themselves can run without a git remote or a network.
  class Facts
    def dirty_tree?
      !`git status --porcelain`.strip.empty?
    end

    def synchronised?
      system('git', 'fetch', '--quiet', 'origin', exception: false)
      local = `git rev-parse HEAD`.strip
      upstream = `git rev-parse @{u} 2>/dev/null`.strip
      !local.empty? && local == upstream
    end

    def tag?(name)
      system("git rev-parse -q --verify refs/tags/#{name} > /dev/null")
    end

    def changelog
      File.read('CHANGELOG.md')
    end

    # Raises rather than guessing when RubyGems cannot be reached: silence would
    # read as "not published", which is the wrong way to be wrong here.
    def published_versions
      uri = URI('https://rubygems.org/api/v1/versions/paper_trail_diff.json')
      JSON.parse(Net::HTTP.get(uri)).map { |release| release['number'] }
    end
  end

  def initialize(version, facts: Facts.new, output: $stdout)
    @version = version
    @facts = facts
    @output = output
    @failures = []
  end

  # Returns true when the release may proceed.
  def call
    clean_working_tree
    synchronised_with_origin
    unused_tag
    changelog_section
    unpublished_version
    report
    @failures.empty?
  end

  private

  attr_reader :version, :facts, :output

  def clean_working_tree
    return unless facts.dirty_tree?

    fail_with('the working tree has uncommitted changes',
              'a tag would name a commit that differs from what was tested')
  end

  def synchronised_with_origin
    return if facts.synchronised?

    fail_with('HEAD does not match its upstream branch',
              'CI has not run against the commit the tag would point at')
  end

  def unused_tag
    return unless facts.tag?("v#{version}")

    fail_with("tag v#{version} already exists",
              'a published tag must never be moved to include later work')
  end

  def changelog_section
    return if facts.changelog.match?(/^## \[#{Regexp.escape(version)}\] - \d{4}-\d{2}-\d{2}$/)

    fail_with("CHANGELOG.md has no dated section for #{version}",
              'the `Unreleased` heading still needs replacing with the version and date')
  end

  # Network trouble is not evidence either way, so it is reported as unknown
  # rather than quietly treated as "not published".
  def unpublished_version
    return unless facts.published_versions.include?(version)

    fail_with("#{version} is already published on RubyGems",
              'a released version can never be replaced, only superseded')
  rescue StandardError => e
    output.puts("  ? could not reach RubyGems to check for #{version} (#{e.class})")
  end

  def fail_with(problem, reason)
    @failures << "  x #{problem}\n    #{reason}"
  end

  def report
    return output.puts("Release preflight passed for #{version}.") if @failures.empty?

    output.puts(['Release preflight failed:', *@failures].join("\n"))
  end
end
