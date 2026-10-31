# frozen_string_literal: true

RSpec.describe PaperTrailDiff::ActivityView do
  let(:policy) { PaperTrailDiff::IgnorePolicy.build([], association_paths: []) }

  it 'groups by transaction or not at all' do
    expect(described_class.new(group: :transaction)).to be_frozen
    expect { described_class.new(group: :day) }
      .to raise_error(PaperTrailDiff::ConfigurationError, 'group: must be :transaction or nil')
  end

  it 'refuses the options only an activity view uses without one' do
    none = { snapshots: false, group: nil, recorded: nil }
    { { snapshots: true } => 'snapshots', { recorded: policy } => 'recorded_changes',
      { group: :transaction } => 'group' }.each do |given, name|
      options = none.merge(given)

      expect { described_class.build(activity: false, **options) }
        .to raise_error(PaperTrailDiff::ConfigurationError, "#{name}: requires activity: true")
      expect(described_class.build(activity: true, **options)).to be_a(described_class)
    end
    expect(described_class.build(activity: false, snapshots: false, group: nil, recorded: nil))
      .to be_a(described_class)
  end

  it 'builds a view of the options it was given' do
    view = described_class.build(activity: true, snapshots: true, group: nil, recorded: policy)

    expect(view.retain?).to be(true)
    expect(view.recorded_attributes(root: true)).to eq(policy.recorded_attributes(root: true))
    expect(view.recorded_attributes(root: true)).to be_an(Array)
  end

  it 'checks the group before what needs an activity view' do
    expect { described_class.build(activity: false, snapshots: true, group: :day, recorded: nil) }
      .to raise_error(PaperTrailDiff::ConfigurationError, 'group: must be :transaction or nil')
  end

  it 'keeps snapshots while building when asked to, or when grouping needs them' do
    expect(described_class.new.retain?).to be(false)
    expect(described_class.new(snapshots: true).retain?).to be(true)
    expect(described_class.new(group: :transaction).retain?).to be(true)
  end

  it 'reads recorded attributes only when they were asked for' do
    recorded = instance_double(PaperTrailDiff::IgnorePolicy)
    allow(recorded).to receive(:recorded_attributes) { |root:| root ? ['title'] : %w[title body] }

    view = described_class.new(recorded: recorded)

    expect(view.recorded_attributes(root: true)).to eq(['title'])
    expect(view.recorded_attributes(root: false)).to eq(%w[title body])
    expect(described_class.new.recorded_attributes(root: true)).to be_nil
  end

  it 'merges steps by transaction only when grouping, keeping snapshots only when asked' do
    steps = [instance_double(PaperTrailDiff::ActivityStep)]
    grouper = instance_double(PaperTrailDiff::ActivityTransactionGrouper, call: [:grouped])
    allow(PaperTrailDiff::ActivityTransactionGrouper).to receive(:new).and_return(grouper)

    expect(described_class.new(snapshots: true).present(steps)).to equal(steps)
    expect(described_class.new(group: :transaction).present(steps)).to eq([:grouped])
    described_class.new(group: :transaction, snapshots: true).present(steps)

    expect(PaperTrailDiff::ActivityTransactionGrouper).to have_received(:new)
      .with(steps, retain: false).ordered
    expect(PaperTrailDiff::ActivityTransactionGrouper).to have_received(:new)
      .with(steps, retain: true).ordered
  end
end
