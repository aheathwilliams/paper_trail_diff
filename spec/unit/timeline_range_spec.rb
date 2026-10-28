# frozen_string_literal: true

# TimelineRange checks the request and hands version selection to VersionRange
# or TimeVersionRange, so those are doubles here and their own specs and the
# integration specs cover what they select.
RSpec.describe PaperTrailDiff::TimelineRange do
  # A versioned record as far as Endpoint can tell: it names its versions
  # association and answers the questions Endpoint.record? asks.
  def self.record_class
    Class.new do
      attr_reader :versions

      def self.versions_association_name = :versions
      def self.base_class = self

      def initialize(versions)
        @versions = versions
      end

      def persisted? = true
      def destroyed? = false
    end
  end
  let(:history) { instance_double(ActiveRecord::Relation) }
  let(:record) { self.class.record_class.new(history) }
  let(:plan) { PaperTrailDiff::RootVersionPlan.closing_on(Object.new) }

  def start_time = Time.utc(2032, 2, 1, 12)
  def window = start_time...(start_time + 3600)

  def history_with(*versions)
    allow(history).to receive(:reorder).with(created_at: :asc, id: :asc).and_return(versions)
  end

  def range(from: nil, to: nil, within: nil, **options)
    described_class.new(record, from: from, to: to, within: within, **options)
  end

  def version_range(method)
    double = instance_double(PaperTrailDiff::VersionRange, method => plan)
    allow(PaperTrailDiff::VersionRange).to receive(:new).and_return(double)
    double
  end

  describe 'checking the request' do
    it 'accepts both endpoints, or a window alone' do
      expect(range(from: 1, to: 2)).to be_frozen
      expect(range(within: window)).to be_frozen
    end

    it 'rejects a missing endpoint' do
      [{ from: 1 }, { to: 2 }, {}].each do |endpoints|
        message = 'provide both `from` and `to`, or provide `within`'
        expect { range(**endpoints) }
          .to raise_error(PaperTrailDiff::InvalidTimelineRangeError, message)
      end
    end

    it 'rejects a window combined with an endpoint' do
      [{ from: 1 }, { to: 2 }, { from: 1, to: 2 }].each do |endpoints|
        message = '`within` cannot be combined with `from` or `to`'
        expect { range(within: window, **endpoints) }
          .to raise_error(PaperTrailDiff::InvalidTimelineRangeError, message)
      end
    end

    it 'rejects :last, saying why' do
      expect { range(from: 1, to: :last) }
        .to raise_error(PaperTrailDiff::InvalidTimelineRangeError, described_class::LAST_REMOVED)
    end

    it 'rejects an unknown symbol' do
      expect { range(from: :latest, to: 2) }.to raise_error(
        PaperTrailDiff::InvalidTimelineRangeError,
        'unsupported boundary: :latest; use :first, a version, or a record'
      )
    end
  end

  describe 'endpoints' do
    it 'resolves :first to the oldest version, ordered by time then id' do
      oldest = Object.new
      history_with(oldest, Object.new)

      expect(range(from: :first, to: :first)).to have_attributes(from: oldest, to: oldest)
      expect(range(from: :first, to: :first)).not_to be_unresolved
    end

    it 'passes other endpoints through, including strings' do
      expect(range(from: 'first', to: 2)).to have_attributes(from: 'first', to: 2)
      expect(range(from: 'first', to: 2)).not_to be_unresolved
    end

    it 'is unresolved when :first finds no versions, on either side' do
      history_with

      expect(range(from: :first, to: 2)).to be_unresolved
      expect(range(from: 1, to: :first)).to be_unresolved
    end
  end

  describe 'a window' do
    it 'keeps versions created inside it' do
      inside = Struct.new(:created_at).new(start_time)
      outside = Struct.new(:created_at).new(start_time + 3600)
      windowed = range(within: window)

      expect(windowed).to be_time
      expect(windowed).not_to be_unresolved
      expect(windowed.time_range).to be_a(PaperTrailDiff::TimeRange)
      expect(windowed.begin_time).to eq(start_time)
      expect(windowed.include?(inside)).to be(true)
      expect(windowed.include?(outside)).to be(false)
    end

    it 'selects through TimeVersionRange with the scope and live endpoint' do
      scope = ->(relation) { relation }
      live = Object.new
      selector = instance_double(PaperTrailDiff::TimeVersionRange)
      allow(PaperTrailDiff::TimeVersionRange).to receive(:new).and_return(selector)
      allow(selector).to receive(:select_plan).and_return(plan)

      windowed = range(within: window, version_scope: scope, live_endpoint: live)

      expect(windowed.select_plan(context_required: true)).to equal(plan)
      expect(windowed.select_plan).to equal(plan)
      expect(PaperTrailDiff::TimeVersionRange).to have_received(:new).with(
        record, time_range: windowed.time_range, version_scope: scope, live_endpoint: live
      ).twice
      expect(selector).to have_received(:select_plan).with(context_required: true).once
      expect(selector).to have_received(:select_plan).with(context_required: false).once
    end
  end

  describe 'explicit endpoints' do
    it 'are not a window, so every version is in range' do
      explicit = range(from: 1, to: 2)

      expect(explicit).not_to be_time
      expect(explicit.time_range).to be_nil
      expect(explicit.begin_time).to be_nil
      expect(explicit.include?(Struct.new(:created_at).new(start_time))).to be(true)
    end

    it 'select between two versions through VersionRange' do
      scope = ->(relation) { relation }
      selector = version_range(:select_plan_for_range)

      expect(range(from: 1, to: 2, version_scope: scope).select_plan).to equal(plan)
      expect(PaperTrailDiff::VersionRange).to have_received(:new)
        .with(record, from: 1, to: 2, version_scope: scope)
      expect(selector).to have_received(:select_plan_for_range)
    end

    it 'select through current state when the range ends at a record' do
      scope = ->(relation) { relation }
      selector = version_range(:select_plan_through_current)

      expect(range(from: 1, to: record, version_scope: scope).select_plan).to equal(plan)
      expect(PaperTrailDiff::VersionRange).to have_received(:new)
        .with(record, from: 1, to: 1, version_scope: scope)
      expect(selector).to have_received(:select_plan_through_current).with(record)
    end

    it 'select nothing when :first finds no versions' do
      history_with
      allow(PaperTrailDiff::VersionRange).to receive(:new)

      expect(range(from: :first, to: record).select_plan).to be_empty
      expect(PaperTrailDiff::VersionRange).not_to have_received(:new)
    end
  end

  it 'returns a plan a batch already selected, without selecting again' do
    allow(PaperTrailDiff::VersionRange).to receive(:new)
    allow(PaperTrailDiff::TimeVersionRange).to receive(:new)

    expect(range(from: 1, to: 2, plan: plan).select_plan).to equal(plan)
    expect(range(within: window, plan: plan).select_plan).to equal(plan)
    expect(PaperTrailDiff::VersionRange).not_to have_received(:new)
    expect(PaperTrailDiff::TimeVersionRange).not_to have_received(:new)
  end
end
