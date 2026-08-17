# frozen_string_literal: true

require_relative '../../script/ruby_floor_check'

# Stands in for the installed Rubies and the gemspec, so every branch runs
# without needing a second Ruby on the machine -- including the failure branch,
# which is the whole point of the check and would otherwise never be exercised.
class StubFloorFacts
  attr_accessor :floor, :current, :available, :result, :calls

  def initialize
    @floor = '3.1'
    @current = '4.0.1'
    @available = true
    @result = [true, '']
    @calls = []
  end

  def declared_floor(_path) = @floor
  def current_version = @current
  def floor_available?(_floor) = @available

  def load_under(floor, load_paths, current:)
    @calls << { floor: floor, load_paths: load_paths, current: current }
    @result
  end
end

RSpec.describe RubyFloorCheck do
  let(:facts) { StubFloorFacts.new }
  let(:output) { StringIO.new }

  def run
    described_class.new('paper_trail_diff.gemspec', facts: facts, output: output).call
  end

  it 'passes when the library loads under the declared floor' do
    expect(run).to be(true)
    expect(output.string).to include('loads under Ruby 3.1')
    expect(facts.calls.first[:current]).to be(false)
  end

  it 'fails and shows the error when the library does not load' do
    facts.result = [false, "support.rb:7: uninitialized constant Data (NameError)\n"]

    expect(run).to be(false)
    expect(output.string).to include('does not load under Ruby 3.1')
    expect(output.string).to include('uninitialized constant Data')
    expect(output.string).to include('raise required_ruby_version')
  end

  # A developer without the floor Ruby installed should still be able to run the
  # gate. CI covers the real matrix; this only shortens the feedback loop.
  it 'skips rather than failing when no floor Ruby is installed' do
    facts.available = false

    expect(run).to be(true)
    expect(output.string).to include('skipped, no Ruby 3.1 available')
    expect(facts.calls).to be_empty
  end

  it 'uses the running Ruby when it already is the floor' do
    facts.current = '3.1.7'

    expect(run).to be(true)
    expect(facts.calls.first[:current]).to be(true)
    expect(output.string).to include('loads under this Ruby')
  end

  it 'skips when the gemspec declares no floor' do
    facts.floor = nil

    expect(run).to be(true)
    expect(output.string).to include('no required_ruby_version')
    expect(facts.calls).to be_empty
  end

  it 'stubs the external requires so the load needs no gems' do
    run

    stub_dir = facts.calls.first[:load_paths].first
    expect(facts.calls.first[:load_paths].last).to eq('lib')
    # The directory is removed once the check finishes, so assert on what was
    # written rather than on what survives.
    expect(described_class::STUBS.keys)
      .to contain_exactly('paper_trail.rb', 'active_support/notifications.rb')
    expect(stub_dir).to include('paper_trail_diff_floor')
  end

  describe 'reading the floor from the gemspec' do
    it 'finds the version this project actually declares' do
      floor = described_class::Facts.new.declared_floor('paper_trail_diff.gemspec')

      expect(floor).to eq('3.1')
    end
  end
end
