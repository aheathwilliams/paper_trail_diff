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

  transactional_class = Struct.new(:id, :created_at, :transaction_id) do
    def reify; end

    def item_type
      'Article'
    end

    def item_id
      1
    end
  end

  define_method(:in_transaction) do |id, at, transaction|
    transactional_class.new(id, at, transaction)
  end

  let(:noon) { Time.utc(2032, 1, 1, 12) }

  define_method(:version) { |id, at| version_class.new(id, at) }

  def range(start_boundary, end_boundary)
    described_class.new(start_boundary, end_boundary)
  end

  it 'reads its start time from a version or a time' do
    expect([range(version(1, noon), version(2, noon + 60)).start_time,
            range(noon + 5, noon + 60).start_time]).to eq([noon, noon + 5])
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

  # A range starting at a version starts before that version's transaction,
  # where PT-AT reads associations. A child version saved earlier in it, as
  # `touch: true` saves one, is inside the range.
  it 'includes versions saved earlier in the transaction of a version start' do
    window = range(in_transaction(5, noon, 40), noon + 60)
    candidates = [in_transaction(3, noon - 1, 40), in_transaction(4, noon - 1, 39),
                  in_transaction(1, noon - 1, nil)]

    expect(candidates.map { |candidate| window.include?(candidate) }).to eq([true, false, false])
    expect(range(noon, noon + 60).include?(candidates.first)).to be(false)
    expect(range(in_transaction(5, noon, nil), noon + 60).include?(candidates.last)).to be(false)
  end

  it 'raises rather than order versions without comparable timestamps' do
    window = range(version(5, noon), version(8, noon + 60))
    message = 'versions have incomparable timestamps'

    expect { window.include?(version(6, nil)) }
      .to raise_error(PaperTrailDiff::ConfigurationError, message)
    expect { range(version(5, nil), version(8, noon + 60)).include?(version(6, noon)) }
      .to raise_error(PaperTrailDiff::ConfigurationError, message)
  end
end
