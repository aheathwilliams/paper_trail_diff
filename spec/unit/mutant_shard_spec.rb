# frozen_string_literal: true

require_relative '../../script/mutant_shard'

RSpec.describe MutantShard do
  let(:listing) do
    "Subjects in environment: 5\nFoo#a\nFoo#b?\nFoo::Bar.c\nBaz#d=\nBaz#e\n"
  end

  before do
    allow(Open3).to receive(:capture2).and_return([listing, double(success?: true)])
    allow(described_class).to receive(:system).and_return(true)
  end

  it 'mutates every nth subject changed since the base revision' do
    expect(described_class.call(1, 2, 'origin/main')).to be(true)

    expect(Open3).to have_received(:capture2)
      .with('bundle', 'exec', 'mutant', 'environment', 'subject', 'list', '--since', 'origin/main')
    expect(described_class).to have_received(:system)
      .with('bundle', 'exec', 'mutant', 'run', '--since', 'origin/main', 'Foo#b?', 'Baz#d=')
  end

  it 'mutates every configured subject without a base revision' do
    described_class.call(0, 2)

    expect(Open3).to have_received(:capture2).with('bundle', 'exec', 'mutant', 'environment',
                                                   'subject', 'list')
    expect(described_class).to have_received(:system)
      .with('bundle', 'exec', 'mutant', 'run', 'Foo#a', 'Foo::Bar.c', 'Baz#e')
  end

  it 'runs nothing for a shard without subjects, which would mutate everything' do
    allow($stdout).to receive(:puts)

    expect(described_class.call(5, 6, 'origin/main')).to be(true)
    expect(described_class).not_to have_received(:system)
  end

  it 'reports the run failing' do
    allow(described_class).to receive(:system).and_return(false)

    expect(described_class.call(0, 1)).to be(false)
  end

  it 'stops when mutant cannot list the subjects' do
    allow(Open3).to receive(:capture2).and_return(['', double(success?: false)])

    expect { described_class.call(0, 1) }.to raise_error(SystemExit)
  end
end
