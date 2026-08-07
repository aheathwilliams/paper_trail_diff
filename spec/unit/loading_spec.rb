# frozen_string_literal: true

RSpec.describe PaperTrailDiff do
  it 'loads without association tracking' do
    expect(defined?(PaperTrail::VersionAssociation)).to be_nil
    expect(described_class::VERSION).to eq('0.1.0')
  end
end
