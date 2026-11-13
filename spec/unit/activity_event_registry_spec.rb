# frozen_string_literal: true

require 'paper_trail_diff'

RSpec.describe PaperTrailDiff::ActivityEventRegistry do
  def row(id)
    Struct.new(:id).new(id)
  end

  def events(registry)
    registry.to_a.map { |event| [event.version.id, event.branches, event.joins] }
  end

  it 'merges the branches of one row, by its key, and the branches it joins' do
    registry = described_class.new
    registry.add([row(1)], branch: 'a', join: true)
    registry.add([row(1), row(2)], branch: 'c')
    registry.add([row(1)], branch: 'b', join: true)

    expect(events(registry)).to eq([[1, %w[a b c], %w[a b]], [2, ['c'], []]])
  end

  it "keeps the root's own versions as root events, joining nothing" do
    registry = described_class.new
    registry.add([row(1)], branch: 'a', join: true)
    registry.add([row(1)], join: true)

    expect(events(registry)).to eq([[1, nil, ['a']]])
    registry.add([row(2)], join: true)
    expect(events(registry).last).to eq([2, nil, []])
  end
end
