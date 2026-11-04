# frozen_string_literal: true

require 'paper_trail_diff'

RSpec.describe PaperTrailDiff::RecordedColumns do
  # PaperTrail keeps each option as names, or hashes of names to conditions.
  def model(**options)
    paper_trail = { ignore: [], skip: [], only: [] }.merge(options)
    Class.new { define_singleton_method(:paper_trail_options) { paper_trail } }
  end

  let(:condition) { ->(_record) { true } }

  it 'counts every column of a model PaperTrail versions without options' do
    expect(described_class.recorded?(model, 'title')).to be(true)
  end

  it 'leaves out a column that ignore: or skip: names, with a condition or without' do
    expect(described_class.recorded?(model(ignore: ['title']), 'title')).to be(false)
    expect(described_class.recorded?(model(ignore: ['rank']), 'title')).to be(true)
    expect(described_class.recorded?(model(skip: ['title']), 'title')).to be(false)
    expect(described_class.recorded?(model(ignore: [{ 'title' => condition }]), 'title'))
      .to be(false)
    expect(described_class.recorded?(model(ignore: [{ 'rank' => condition }]), 'title'))
      .to be(true)
    indifferent = ActiveSupport::HashWithIndifferentAccess.new('title' => condition)
    expect(described_class.recorded?(model(skip: [indifferent]), 'title')).to be(false)
  end

  it 'counts only the columns only: names without a condition' do
    expect(described_class.recorded?(model(only: ['title']), 'title')).to be(true)
    expect(described_class.recorded?(model(only: ['title']), 'rank')).to be(false)
    expect(described_class.recorded?(model(only: [{ 'title' => condition }]), 'title'))
      .to be(false)
  end

  it 'counts nothing for a model PaperTrail does not version' do
    expect(described_class.recorded?(Class.new, 'title')).to be(false)
  end
end
