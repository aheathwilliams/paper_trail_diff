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

  it 'takes only true or false for its switches' do
    none = { activity: true, snapshots: false, group: nil, recorded: nil }
    neither = ['yes', nil]
    %i[activity snapshots].each do |name|
      neither.each do |value|
        expect { described_class.build(**none, name => value) }
          .to raise_error(PaperTrailDiff::ConfigurationError, "#{name}: must be true or false")
      end
    end
  end

  it 'builds a view of the options it was given' do
    view = described_class.build(activity: true, snapshots: true, group: nil, recorded: policy,
                                 version_scope: :all.to_proc)

    expect(view.retain?).to be(true)
    expect(view.recorded_reader(root: true)).to be_a(PaperTrailDiff::RecordedChangesReader)
    expect(view.version_filter).to be_a(PaperTrailDiff::ActivityScopeFilter)
  end

  # One filter answers for the whole request, with the scope it was given.
  it 'keeps one version filter for the request when given a scope, and none otherwise' do
    scope = ->(versions) { versions }
    allow(PaperTrailDiff::ActivityScopeFilter).to receive(:new).and_call_original

    view = described_class.new(version_scope: scope)

    expect(view.version_filter).to be_a(PaperTrailDiff::ActivityScopeFilter)
    expect(view.version_filter).to equal(view.version_filter)
    expect(PaperTrailDiff::ActivityScopeFilter).to have_received(:new).with(scope).once
    expect(described_class.new.version_filter).to be_nil
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

  # Each reader decodes a version once for the whole request, leaving out the
  # names ignored on its side.
  it 'reads recorded changes only when they were asked for, once per version' do
    recorded = instance_double(PaperTrailDiff::IgnorePolicy)
    allow(recorded).to receive(:recorded_attributes) { |root:| root ? ['title'] : %w[title body] }
    allow(PaperTrailDiff::RecordedChanges).to receive(:call) { |_version, ignore:| ignore }
    version = Struct.new(:id).new(1)

    view = described_class.new(recorded: recorded)

    expect(Array.new(2) { view.recorded_reader(root: true).call(version) }).to eq([['title']] * 2)
    expect(view.recorded_reader(root: false).call(version)).to eq(%w[title body])
    expect(PaperTrailDiff::RecordedChanges).to have_received(:call).twice
    expect(described_class.new.recorded_reader(root: true)).to be_nil
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
