# frozen_string_literal: true

RSpec.describe PaperTrailDiff::InterleavedTransactions do
  before { stub_const('InterleavedVersion', Struct.new(:id, :transaction_id)) }

  def event(id, transaction_id)
    PaperTrailDiff::ActivityEvent.new(version: InterleavedVersion.new(id, transaction_id),
                                      branches: ['comments'])
  end

  def open_at(events, opening: [])
    described_class.call(events, opening: opening).transform_keys(&:last)
  end

  it 'names the other transactions open at each event' do
    events = [event(1, 7), event(2, 8), event(3, 7), event(4, nil), event(5, 8), event(6, 9)]

    expect(open_at(events)).to eq(2 => [7], 3 => [8], 4 => [8])
  end

  it 'opens no transaction for versions saved outside one' do
    events = [event(1, 7), event(2, nil), event(3, 8), event(4, nil), event(5, 8), event(6, 7)]

    expect(open_at(events)).to eq(2 => [7], 3 => [7], 4 => [7, 8], 5 => [7])
  end

  it 'names none where transactions follow one another' do
    expect(open_at([event(1, 7), event(2, 7), event(3, nil), event(4, 8), event(5, 8)])).to eq({})
  end

  it 'opens a transaction that began before the history at its start, until its last event' do
    opening = [['InterleavedVersion', 9], ['InterleavedVersion', 6]]
    events = [event(1, 7), event(2, 9), event(3, nil), event(4, 9)]

    expect(open_at(events, opening: opening)).to eq(1 => [9], 3 => [9])
  end

  it 'names every transaction open at an event' do
    events = [event(1, 7), event(2, 8), event(3, nil), event(4, 8), event(5, 7)]

    expect(open_at(events)).to eq(2 => [7], 3 => [7, 8], 4 => [7])
  end
end
