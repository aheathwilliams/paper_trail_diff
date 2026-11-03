# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::EndpointKind do
  # Each value below lacks one of the methods a version or a record has.
  it 'tells a version from a record, and both from anything else' do
    version = Struct.new(:item_type, :item_id) { def reify = nil }
    record = Struct.new(:persisted?, :destroyed?) { def self.base_class = self }
    values = [
      version.new('A', 1), Struct.new(:item_type, :item_id).new('A', 1),
      Struct.new(:item_id) { def reify = nil }.new(1),
      Struct.new(:item_type) { def reify = nil }.new('A'),
      record.new(true, false), Struct.new(:destroyed?) { def self.base_class = self }.new(false),
      Struct.new(:persisted?) { def self.base_class = self }.new(true),
      Struct.new(:persisted?, :destroyed?).new(true, false)
    ]

    expect(values.map { |value| described_class.call(value) })
      .to eq(%i[version other other other record other other other])
  end

  it 'answers once for each Active Record class' do
    first = FilterArticle.new
    second = FilterArticle.new
    allow(first).to receive(:respond_to?).and_call_original
    allow(second).to receive(:respond_to?).and_call_original

    [first, second].each { |record| described_class.call(record) }

    expect(second).not_to have_received(:respond_to?)
  end
end
