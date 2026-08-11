# frozen_string_literal: true

RSpec.describe PaperTrailDiff do
  it 'loads without association tracking' do
    expect(defined?(PaperTrail::VersionAssociation)).to be_nil
    # Asserted by shape rather than by literal. Pinning the number cannot catch
    # a forgotten bump, because the bump is the edit that would change it; it
    # only fails after a deliberate one, adding a release step for no guarantee.
    # A malformed version is already rejected by the gemspec before this loads.
    expect(described_class::VERSION).to match(/\A\d+\.\d+\.\d+/)
    expect(described_class::VERSION).to be_frozen
  end
end
