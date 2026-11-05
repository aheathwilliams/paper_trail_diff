# frozen_string_literal: true

require 'stringio'
require_relative '../support/oracle_reducer'

# The reducer that edits an oracle history's draws until it is as short as
# still fails (spec/support/oracle_reducer.rb).
RSpec.describe Oracle::Reducer do
  # A history of operations, one per step, that fails when an operation 7 is
  # followed later by an operation 3, whatever each step's second draw.
  def run(scripts)
    operations = scripts.fetch(0).fetch(0).map(&:first)
    seven = operations.index(7)
    failed = seven && operations.drop(seven + 1).include?(3)
    described_class::Run.new(scripts: scripts, exception: (StandardError.new('mismatch') if failed),
                             labels: failed ? ["operation 7 at step #{seven} then 3"] : [])
  end

  # Histories, one a stream, that fail when any of them has an operation 7.
  def run_any(scripts)
    failed = scripts.any? { |items| items.fetch(0, []).any? { |step| step.first == 7 } }
    described_class::Run.new(scripts: scripts, exception: (StandardError.new('mismatch') if failed),
                             labels: failed ? ['operation 7'] : [])
  end

  def reduce(scripts, limit: 300, check: method(:run))
    first = check.call(scripts)
    reduction = described_class::Reduction.new(first, limit: limit, log: StringIO.new) do |edited|
      check.call(edited)
    end
    reduction.call
  end

  let(:history) do
    random = Random.new(5)
    steps = Array.new(24) { [random.rand(10), random.rand(4)] }
    steps.insert(4, [7, 2])
    steps.insert(17, [3, 1])
    [[steps]]
  end

  it 'reduces a failing history to the steps it needs, each draw as small as still fails' do
    reduction = reduce(history)

    expect(reduction.best.scripts).to eq([[[[7, 0], [3, 0]]]])
    expect(reduction.runs).to be < 60
  end

  # An example that builds a history for each seed reruns them all each time,
  # so a history the failure does not need goes whole, before any one step.
  it 'first leaves out the histories a failure does not need, half of them at a time' do
    histories = Array.new(8) do |stream|
      [Array.new(20) { |step| [stream == 5 && step == 9 ? 7 : 0] }]
    end
    after_six = reduce(histories, limit: 6, check: method(:run_any)).best.scripts

    expect(after_six.map { |items| described_class::Script.steps([items]) })
      .to eq([0, 0, 0, 0, 0, 20, 0, 0])
    expect(reduce(histories, check: method(:run_any)).best.scripts)
      .to eq([[], [], [], [], [], [[[7]]], [], []])
  end

  it 'keeps only an edit that fails with the same first mismatch, numbers aside' do
    expect(described_class.generalize('analyze 12->current at 2026-11-04T21:35:01.701265Z'))
      .to eq('analyze N->current at TIME')
  end

  it 'stops at its limit of runs' do
    reduction = reduce(history, limit: 3)

    expect(reduction.runs).to eq(3)
    expect(reduction.best.failed?).to be(true)
  end

  it 'names the example alone, with the settings that decide its history' do
    stub_const('ENV', { 'ORACLE_SEEDS' => '3..4', 'ORACLE_STEPS' => '40' })
    example = Struct.new(:id).new('./spec/oracle/history_spec.rb[1:2]')

    expect(described_class::Replay.command(example, described_class::Hint::SETTINGS,
                                           'ORACLE_SHRINK=1'))
      .to eq('ORACLE_SEEDS=3..4 ORACLE_STEPS=40 ORACLE_SHRINK=1 bundle exec rspec ' \
             "'spec/oracle/history_spec.rb[1:2]'")
    stub_const('ENV', { 'PAPER_TRAIL_DIFF_DATABASE_URL' => 'postgres://ci' })
    expect(described_class::Replay.command(example, [], 'ORACLE_REPLAY=tmp/oracle/a.json'))
      .to eq('ORACLE_REPLAY=tmp/oracle/a.json bundle exec rspec ' \
             "'spec/oracle/history_spec.rb[1:2]', with the same PAPER_TRAIL_DIFF_DATABASE_URL")
  end

  it 'finds every loop and draw in a script' do
    script = [[4, [[1, [[2]]], []], 0.5]]

    expect(described_class::Script.loop_paths(script)).to eq([[0, 1], [0, 1, 0, 1]])
    expect(described_class::Script.draw_paths(script))
      .to eq([[0, 0], [0, 1, 0, 0], [0, 1, 0, 1, 0, 0], [0, 2]])
    expect(described_class::Script.steps(script)).to eq(3)
  end
end
