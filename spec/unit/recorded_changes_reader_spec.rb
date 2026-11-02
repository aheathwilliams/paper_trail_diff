# frozen_string_literal: true

RSpec.describe PaperTrailDiff::RecordedChangesReader do
  # Version classes are named; a reader keys by the name.
  let(:version_class) { stub_const('ReaderSpecVersion', Struct.new(:id)) }

  before { allow(PaperTrailDiff::RecordedChanges).to receive(:call) { |version, ignore:| [version.id, ignore] } }

  it 'decodes each version once, by its class and id, leaving out the names it was given' do
    reader = described_class.new(['title'])
    other = stub_const('ReaderSpecOtherVersion', Struct.new(:id))

    expect([reader.call(version_class.new(1)), reader.call(version_class.new(1)),
            reader.call(version_class.new(2)), reader.call(other.new(1))])
      .to eq([[1, ['title']], [1, ['title']], [2, ['title']], [1, ['title']]])
    expect(PaperTrailDiff::RecordedChanges).to have_received(:call).exactly(3).times
  end

  # Support.row_key: a row still matches after its class is reloaded.
  it 'knows a version again after its class is reloaded' do
    reader = described_class.new([])
    version = version_class.new(1)
    reloaded = stub_const('ReaderSpecVersion', Struct.new(:id))

    expect([reader.call(version), reader.call(reloaded.new(1))]).to eq([[1, []], [1, []]])
    expect(PaperTrailDiff::RecordedChanges).to have_received(:call).once
  end

  # The steps of one result can be read from several threads.
  it 'decodes a version once when two threads ask for it at once' do
    release = Queue.new
    allow(PaperTrailDiff::RecordedChanges).to receive(:call) { release.pop }
    reader = described_class.new([])
    version = version_class.new(1)

    threads = Array.new(2) do
      Thread.new { reader.call(version) }.tap { |thread| Thread.pass until thread.stop? }
    end
    2.times { release << :decoded }

    expect(threads.map(&:value)).to eq(%i[decoded decoded])
    expect(PaperTrailDiff::RecordedChanges).to have_received(:call).once
  end

  it 'keeps a version that recorded nothing, rather than reading it again' do
    allow(PaperTrailDiff::RecordedChanges).to receive(:call).and_return(nil)
    reader = described_class.new([])
    version = version_class.new(1)

    expect([reader.call(version), reader.call(version)]).to eq([nil, nil])
    expect(PaperTrailDiff::RecordedChanges).to have_received(:call).once
  end

  describe PaperTrailDiff::RecordedChangesReader::Pending do
    it 'reads only when asked, once, and then lets go of the version' do
      reader = PaperTrailDiff::RecordedChangesReader.new([])
      allow(reader).to receive(:call).and_call_original
      pending = described_class.new(reader, version_class.new(7))

      expect(reader).not_to have_received(:call)
      expect([pending.value, pending.value]).to eq([[7, []], [7, []]])
      expect(reader).to have_received(:call).once
      expect(pending.instance_variable_get(:@version)).to be_nil
    end

    it 'reads once when two threads ask at once' do
      release = Queue.new
      reader = instance_double(PaperTrailDiff::RecordedChangesReader)
      allow(reader).to receive(:call) { release.pop }
      pending = described_class.new(reader, version_class.new(7))

      threads = Array.new(2) do
        Thread.new { pending.value }.tap { |thread| Thread.pass until thread.stop? }
      end
      2.times { release << :decoded }

      expect(threads.map(&:value)).to eq(%i[decoded decoded])
      expect(reader).to have_received(:call).once
    end
  end
end
