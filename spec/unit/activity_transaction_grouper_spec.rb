# frozen_string_literal: true

require 'paper_trail_diff'

RSpec.describe PaperTrailDiff::ActivityTransactionGrouper do
  def boundary(version_id, transaction_id)
    PaperTrailDiff::ActivityBoundary.new(
      kind: :version, version_id: version_id, item_type: 'Post', item_id: 1,
      recorded_at: Time.utc(2026, 1, 1, 0, 0, version_id), transaction_id: transaction_id
    )
  end

  def snapshot(title)
    PaperTrailDiff::RecordSnapshot.new(type: 'Post', id: 1, attributes: { 'title' => title })
  end

  # Step `index` runs from boundary `index` to boundary `index + 1`, and from
  # titles[index] to titles[index + 1]; transactions[index] is the transaction
  # of its opening boundary.
  def steps(transactions, titles: nil, closing: nil)
    titles ||= Array.new(transactions.size + 1) { |index| "t#{index}" }
    transactions.each_index.map do |index|
      closing_transaction = closing ? closing[index] : transactions[index + 1]
      PaperTrailDiff::ActivityStep.between(
        from_boundary: boundary(index, transactions[index]),
        to_boundary: boundary(index + 1, closing_transaction),
        from_snapshot: snapshot(titles[index]),
        to_snapshot: snapshot(titles[index + 1]),
        retain: true
      )
    end
  end

  def group(transactions, retain: false, **options)
    described_class.new(steps(transactions, **options), retain: retain).call
  end

  def spans(result)
    result.map { |step| [step.from_boundary.version_id, step.to_boundary.version_id] }
  end

  it 'returns no steps for no steps' do
    expect(described_class.new([], retain: false).call).to eq([])
  end

  it 'merges consecutive steps opened in one transaction into one step' do
    result = group([7, 7, 7, 8])

    expect(spans(result)).to eq([[0, 3], [3, 4]])
    expect(result.first.from_boundary.to_h(metadata: true))
      .to eq(boundary(0, 7).to_h(metadata: true))
    expect(result.first.to_boundary.to_h(metadata: true))
      .to eq(boundary(3, 8).to_h(metadata: true))
  end

  it 'groups by the opening boundary, not the closing one' do
    result = group([1, 2, 3], closing: [2, 2, 2])

    expect(spans(result)).to eq([[0, 1], [1, 2], [2, 3]])
  end

  it 'never groups boundaries without a transaction, even with each other' do
    expect(spans(group([nil, nil, 5, 5, nil]))).to eq([[0, 1], [1, 2], [2, 4], [4, 5]])
  end

  it 'starts a new group when a transaction comes back after another' do
    expect(spans(group([4, 5, 4]))).to eq([[0, 1], [1, 2], [2, 3]])
  end

  it 'compares the outer snapshots, so a value set and restored is no change' do
    restored = group([3, 3], titles: %w[same changed same])
    changed = group([3, 3], titles: %w[before middle after])

    expect(restored.first).to be_empty
    expect(changed.first.diff.attributes.fetch('title').to_h).to eq(from: 'before', to: 'after')
  end

  it 'keeps the outer snapshots only when asked, even for a group of one' do
    retained = group([1, 1, 2], retain: true)
    dropped = group([1, 1, 2], retain: false)

    expect(retained.map { |step| [step.from_snapshot.to_h, step.to_snapshot.to_h] })
      .to eq([[snapshot('t0').to_h, snapshot('t2').to_h],
              [snapshot('t2').to_h, snapshot('t3').to_h]])
    expect(dropped.map { |step| [step.from_snapshot, step.to_snapshot] })
      .to eq([[nil, nil], [nil, nil]])
  end

  it 'names every event a merged step holds as its sources, in order' do
    result = group([7, 7, 7, 8])

    expect(result.map { |step| step.sources.map(&:version_id) }).to eq([[0, 1, 2], [3]])
    expect(result.first.source_boundary).to equal(result.first.sources.first)
    expect(result.first.sources).to be_frozen
  end

  it 'keeps the sources of steps that were already groups' do
    first, second = steps([1, 1])
    merged = described_class.new([first, second], retain: true).call
    again = described_class.new(merged, retain: true).call

    expect(again.first.sources.map(&:version_id)).to eq([0, 1])
  end
end
