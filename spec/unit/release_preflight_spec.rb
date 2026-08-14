# frozen_string_literal: true

require_relative '../../script/release_preflight'

# A stand-in for the git working copy and RubyGems, so both outcomes can be
# exercised. Release tooling whose success path has never run is the kind
# that fails on the day it is needed.
class StubFacts
  attr_accessor :dirty, :synced, :tags, :changelog, :published

  def initialize
    @dirty = false
    @synced = true
    @tags = []
    @changelog = "## [1.2.3] - 2026-08-14\n"
    @published = ['1.2.2']
  end

  def dirty_tree? = @dirty
  def synchronised? = @synced
  def tag?(name) = @tags.include?(name)
  def published_versions = @published.is_a?(StandardError) ? raise(@published) : @published
end

RSpec.describe ReleasePreflight do
  let(:facts) { StubFacts.new }
  let(:output) { StringIO.new }

  def run(version = '1.2.3')
    described_class.new(version, facts: facts, output: output).call
  end

  it 'passes when every condition holds' do
    expect(run).to be(true)
    expect(output.string).to include('Release preflight passed for 1.2.3.')
  end

  it 'refuses a dirty working tree, which would tag untested code' do
    facts.dirty = true

    expect(run).to be(false)
    expect(output.string).to include('uncommitted changes')
    expect(output.string).to include('differs from what was tested')
  end

  it 'refuses a commit CI has not seen' do
    facts.synced = false

    expect(run).to be(false)
    expect(output.string).to include('does not match its upstream')
  end

  it 'refuses to reuse a tag' do
    facts.tags = ['v1.2.3']

    expect(run).to be(false)
    expect(output.string).to include('tag v1.2.3 already exists')
  end

  it 'refuses a version whose changelog heading is still Unreleased' do
    facts.changelog = "## [Unreleased]\n"

    expect(run).to be(false)
    expect(output.string).to include('no dated section for 1.2.3')
  end

  it 'refuses a version already on RubyGems' do
    facts.published = %w[1.2.2 1.2.3]

    expect(run).to be(false)
    expect(output.string).to include('already published')
  end

  it 'reports an unreachable RubyGems as unknown rather than as absent' do
    facts.published = SocketError.new('no network')

    # Silence would read as "not published", which is the wrong way to be wrong.
    expect(run).to be(true)
    expect(output.string).to include('could not reach RubyGems')
  end

  it 'collects every failure rather than stopping at the first' do
    facts.dirty = true
    facts.synced = false

    expect(run).to be(false)
    expect(output.string).to include('uncommitted changes').and include('upstream')
  end
end
