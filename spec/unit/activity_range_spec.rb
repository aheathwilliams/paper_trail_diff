# frozen_string_literal: true

RSpec.describe PaperTrailDiff::ActivityRange do
  # Enough of a PaperTrail version for Endpoint.version? and the ordering key.
  version_class = Struct.new(:id, :created_at) do
    def reify; end

    def item_type
      'Article'
    end

    def item_id
      1
    end
  end

  let(:noon) { Time.utc(2032, 1, 1, 12) }

  define_method(:version) { |id, at| version_class.new(id, at) }

  def range(start_boundary, end_boundary)
    described_class.new(start_boundary, end_boundary)
  end

  it 'reads its times from a version or a time at either end' do
    first = version(1, noon)
    last = version(2, noon + 60)

    expect([range(first, last).start_time, range(first, last).end_time]).to eq([noon, noon + 60])
    expect([range(noon, noon + 5).start_time, range(noon, noon + 5).end_time])
      .to eq([noon, noon + 5])
  end

  it 'includes versions at a time boundary on either side' do
    window = range(noon, noon + 60)

    expect([noon - 1, noon, noon + 60, noon + 61].map { |at| window.include?(version(5, at)) })
      .to eq([false, true, true, false])
  end

  # Versions saved in the same instant are ordered by id, so a version
  # boundary keeps itself and splits its neighbors from that instant.
  it 'includes a version boundary itself and orders same-instant versions by id' do
    window = range(version(5, noon), version(8, noon + 60))
    candidates = [version(4, noon), version(5, noon), version(6, noon),
                  version(7, noon + 60), version(8, noon + 60), version(9, noon + 60)]

    expect(candidates.map { |candidate| window.include?(candidate) })
      .to eq([false, true, true, true, true, false])
  end

  it 'mixes a version start with a time end and the reverse' do
    from_version = range(version(5, noon), noon + 60)
    to_version = range(noon, version(8, noon + 60))

    expect([version(4, noon), version(6, noon + 60), version(1, noon + 61)]
             .map { |candidate| from_version.include?(candidate) }).to eq([false, true, false])
    expect([version(1, noon - 1), version(1, noon), version(9, noon + 60)]
             .map { |candidate| to_version.include?(candidate) }).to eq([false, true, false])
  end

  it 'narrows a relation to the timestamps between its ends' do
    relation = Object.new.tap { |where| where.define_singleton_method(:where) { |hash| hash } }

    expect(range(version(5, noon), noon + 60).scope(relation))
      .to eq(created_at: noon..(noon + 60))
  end

  it 'ends at the current record only when its end is not a version' do
    expect(range(noon, noon + 60).current_end?).to be(true)
    expect(range(noon, version(8, noon + 60)).current_end?).to be(false)
  end

  # A version records the state after its change, and a range that ends at a
  # version ends just before that change.
  it 'places the state a version recorded strictly before a version end' do
    window = range(noon, version(8, noon + 60))

    expect([[noon + 59, 99], [noon + 60, 7], [noon + 60, 8], [noon + 60, 9], [noon + 61, 1]]
             .map { |at, id| window.recorded_before_end?(at, id) })
      .to eq([true, true, false, false, false])
  end

  it 'places the state recorded at a time end inside the range' do
    window = range(noon, noon + 60)

    expect([noon + 59, noon + 60, noon + 61].map { |at| window.recorded_before_end?(at, 1) })
      .to eq([true, true, false])
  end

  it 'raises rather than order versions without comparable timestamps' do
    window = range(version(5, noon), version(8, noon + 60))
    message = 'versions have incomparable timestamps'

    expect { window.include?(version(6, nil)) }
      .to raise_error(PaperTrailDiff::ConfigurationError, message)
    expect { range(version(5, nil), version(8, noon + 60)).include?(version(6, noon)) }
      .to raise_error(PaperTrailDiff::ConfigurationError, message)
    expect { window.recorded_before_end?(nil, 6) }
      .to raise_error(PaperTrailDiff::ConfigurationError, message)
  end
end
