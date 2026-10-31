# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PaperTrailDiff::FallbackPaths do
  def reflection(foreign_key: 'article_id', belongs_to: false, polymorphic: false, through: nil)
    instance_double(reflection_class(belongs_to, through),
                    foreign_key: foreign_key, belongs_to?: belongs_to, polymorphic?: polymorphic,
                    through_reflection?: !through.nil?, through_reflection: through&.first,
                    source_reflection: through&.last)
  end

  def reflection_class(belongs_to, through)
    return ActiveRecord::Reflection::ThroughReflection if through

    belongs_to ? ActiveRecord::Reflection::BelongsToReflection : ActiveRecord::Reflection::HasManyReflection
  end

  def traversal(*reflections)
    pairs = reflections.each_with_index.map { |reflection, index| ["path#{index}", reflection] }
    traversal = instance_double(PaperTrailDiff::AssociationTraversal)
    allow(traversal).to receive(:selected_reflections).with(:model).and_return(pairs)
    traversal
  end

  def any?(traversal, approximate: true)
    described_class.any?(traversal, :model, approximate: approximate)
  end

  before { allow(PaperTrailDiff::ApproximatePaths).to receive(:call).and_return([]) }

  it 'counts a path history reads only approximately when it is allowed' do
    plain = traversal(reflection)
    allow(PaperTrailDiff::ApproximatePaths).to receive(:call)
      .with(plain, :model).and_return([['comments', 'association scope']])

    expect(any?(plain, approximate: true)).to be(true)
    expect(any?(plain, approximate: false)).to be(false)
  end

  it 'leaves out plain paths loaded history reads' do
    expect(any?(traversal(reflection, reflection(belongs_to: true)))).to be(false)
  end

  it 'counts a composite foreign key, on the path or on a part of a through' do
    # An Array subclass, as a composite key may be, so only `is_a?` sees it.
    composite = reflection(foreign_key: Class.new(Array).new(%w[shop_id order_id]))

    expect(any?(traversal(reflection, composite))).to be(true)
    expect(any?(traversal(reflection(through: [composite, reflection])))).to be(true)
    expect(any?(traversal(reflection(through: [reflection, composite])))).to be(true)
    expect(any?(traversal(reflection(through: [reflection, reflection])))).to be(false)
  end

  it 'counts a polymorphic belongs_to, whose target is known only per record' do
    expect(any?(traversal(reflection(belongs_to: true, polymorphic: true)))).to be(true)
    expect(any?(traversal(reflection(polymorphic: true)))).to be(false)
  end
end
