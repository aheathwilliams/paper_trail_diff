# frozen_string_literal: true

RSpec.describe PaperTrailDiff::RootVersionPlan do
  # Plans only read a version's class name and id. Two objects with the same id
  # are still different objects here, as unsaved or reloaded records can be.
  def self.version_class
    Class.new do
      attr_reader :id

      def initialize(id)
        @id = id
      end
    end
  end

  let(:version_class) { stub_const('PlanVersion', self.class.version_class) }
  let(:other_version_class) { stub_const('OtherPlanVersion', self.class.version_class) }
  let(:first) { version_class.new(1) }
  let(:second) { version_class.new(2) }
  let(:third) { version_class.new(3) }

  describe '.contiguous' do
    it 'steps between adjacent versions and reports each as a mutation' do
      plan = described_class.contiguous([first, second, third])

      expect(plan.versions).to eq([first, second, third])
      expect(plan.steps).to eq([[first, second], [second, third]])
      expect(plan.reconstruction_versions).to eq([first, second, third])
      expect(plan.mutations).to eq([first, second, third])
      expect(plan.context_version).to be_nil
      expect(plan).not_to be_empty
    end

    it 'leaves the context version out of the mutations' do
      context = version_class.new(1)
      plan = described_class.contiguous([first, second, third], context_version: context)

      expect(plan.context_version).to equal(context)
      expect(plan.mutations).to eq([second, third])
      expect(plan.mutation?(first)).to be(false)
      expect(plan.mutation?(second)).to be(true)
    end
  end

  it 'starts empty, with nothing to close on' do
    plan = described_class.empty

    expect(plan).to be_empty
    expect(plan.versions).to eq([])
    expect(plan.steps).to eq([])
    expect(plan.closing_record).to be_nil
    expect(plan.final_endpoint).to be_nil
    expect(plan.closes_on_destroy).to be(false)
  end

  it 'closes on a live record with no versions' do
    record = Object.new
    plan = described_class.closing_on(record)

    expect(plan).to be_empty
    expect(plan.steps).to eq([])
    expect(plan.closing_record).to equal(record)
    expect(plan.final_endpoint).to equal(record)
  end

  it 'ends at the closing record when there is one, otherwise the last version' do
    record = Object.new

    expect(described_class.contiguous([first, second]).final_endpoint).to equal(second)
    expect(described_class.new(versions: [first], steps: [], closing_record: record).final_endpoint)
      .to equal(record)
  end

  it 'keeps reconstruction versions and mutations given explicitly' do
    plan = described_class.new(
      versions: [first, third], steps: [[first, third]],
      reconstruction_versions: [first, second, third], mutations: [first]
    )

    expect(plan.reconstruction_versions).to eq([first, second, third])
    expect(plan.mutations).to eq([first])
    expect(plan.mutation?(third)).to be(false)
  end

  it 'recognizes a mutation by version class and id, not by object' do
    plan = described_class.contiguous([first])

    expect(plan.mutation?(version_class.new(1))).to be(true)
    expect(plan.mutation?(other_version_class.new(1))).to be(false)
    expect(plan.mutation?(version_class.new(2))).to be(false)
  end

  it 'still recognizes a mutation after its version class is reloaded' do
    plan = described_class.contiguous([first])
    reloaded = self.class.version_class
    reloaded.define_singleton_method(:name) { 'PlanVersion' }

    expect(plan.mutation?(reloaded.new(1))).to be(true)
  end

  it 'copies everything into a plan that closes on destruction' do
    record = Object.new
    plan = described_class.new(
      versions: [first, third], steps: [[first, third]], context_version: first,
      reconstruction_versions: [first, second, third], mutations: [first], closing_record: record
    )

    closing = plan.closing_on_destroy

    expect(closing.closes_on_destroy).to be(true)
    expect(plan.closes_on_destroy).to be(false)
    expect(closing.versions).to eq(plan.versions)
    expect(closing.steps).to eq(plan.steps)
    expect(closing.context_version).to equal(first)
    expect(closing.reconstruction_versions).to eq(plan.reconstruction_versions)
    expect(closing.mutations).to eq([first])
    expect(closing.closing_record).to equal(record)
  end

  it 'is frozen, along with its lists' do
    given = described_class.new(
      versions: [first, second], steps: [[first, second]],
      reconstruction_versions: [first, second, third], mutations: [second]
    )
    derived = described_class.contiguous([first, second], context_version: first)

    expect([given, derived]).to all(be_frozen)
    expect([given.versions, given.steps, given.reconstruction_versions, given.mutations])
      .to all(be_frozen)
    expect(derived.mutations).to be_frozen
  end
end
