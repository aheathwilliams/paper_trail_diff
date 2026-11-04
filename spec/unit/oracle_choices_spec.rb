# frozen_string_literal: true

require_relative '../support/oracle_choices'

# The oracle generators' random source (spec/support/oracle_choices.rb).
RSpec.describe Oracle::Choices do
  # Draws as the generators make them.
  def draws(random)
    list = (1..20).to_a
    [list.sample(random: random), list.sample(3, random: random), list.shuffle(random: random),
     list.first(1).sample(random: random), random.rand, random.rand(7), random.rand(2..5)]
  end

  it 'hands out what Random would from the same seed' do
    choices = described_class.new(4)
    random = Random.new(4)
    indexes = []
    choices.steps(3) { |index| indexes << index }

    expect(Array.new(30) { draws(choices) }).to eq(Array.new(30) { draws(random) })
    expect(indexes).to eq([0, 1, 2])
  end

  it 'keeps each draw, and each loop as one list of draws per step' do
    choices = described_class.new(9)
    first = choices.rand(5)
    loop = []
    choices.steps(2) { |index| loop << [index, choices.rand(4), choices.rand(1..3)] }

    expect(choices.script).to eq([first, loop.map { |_, value, ranged| [value, ranged - 1] }])
  end

  it 'replays a script, and leaves 0 where it holds no draw' do
    replay = described_class.new(1, replay: [3, [[2, 1], [5]], 0.25])
    values = [replay.rand(10)]
    replay.steps(10) { values << [replay.rand(4), replay.rand(1..9)] }
    values += [replay.rand, replay.rand, replay.rand(6)]

    expect(values).to eq([3, [2, 2], [3, 1], 0.25, 0.0, 0])
    expect(replay.script).to eq([3, [[2, 1], [3, 0]], 0.25, 0.0, 0])
  end

  # So a step can be left out without changing what the steps after it do.
  it 'gives each step its own draws, whatever the steps before it drew' do
    replay = described_class.new(1, replay: [[[7, 7, 7], [1, 2]]])
    values = []
    replay.steps(2) { values << [replay.rand(9)] }

    expect(values).to eq([[7], [1]])
  end

  it 'fits a kept draw to the limit it is drawn for' do
    replay = described_class.new(1, replay: [9, 0.75, 9, 4])

    expect([replay.rand(3), replay.rand(4), replay.rand(1...4), replay.rand]).to eq([2, 3, 3, 0.0])
  end

  it 'refuses a limit it could not replay' do
    expect { described_class.new(1).rand(2.5) }.to raise_error(ArgumentError, /rand\(2.5\)/)
    expect { described_class.new(1).rand(0) }.to raise_error(ArgumentError)
    expect { described_class.new(1).rand(1..) }.to raise_error(ArgumentError)
  end
end
