# frozen_string_literal: true

require 'paper_trail_diff'

RSpec.describe PaperTrailDiff::ActivityEvent do
  let(:version) { Struct.new(:id).new(1) }

  it 'holds its branches and the branches it joins once each, sorted and frozen' do
    event = described_class.new(version: version, branches: %w[b a b], joins: %w[d c d])

    expect(event.branches).to eq(%w[a b]).and be_frozen
    expect(event.joins).to eq(%w[c d]).and be_frozen
    expect(event.version).to equal(version)
    expect(event).to be_frozen
    expect(event).not_to be_root
  end

  it "is the root's own, with no branches, and joins none unless told" do
    event = described_class.new(version: version, branches: nil)

    expect(event.branches).to be_nil
    expect(event.joins).to eq([])
    expect(event).to be_root
  end
end
