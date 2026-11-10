# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::AnalysisBatch do
  let(:analyzed) { [] }
  let(:prepared) { [] }
  let(:loaded) { [] }
  let(:analyzer) do
    analyze = lambda do |record, plan, window|
      analyzed << [record, plan, window]
      AnalysisStandIn.new(record.id)
    end
    analyze.tap { |call| call.define_singleton_method(:empty) { AnalysisStandIn.new(nil) } }
  end
  let(:history_preparer) do
    lambda do |records, versions, reach: true, **range|
      prepared << [records, versions, range]
      reaches.shift if reach
    end
  end

  # How far the history of each read says its transactions reach, in turn.
  def reaches = (@reaches ||= [])
  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
    # Stands in for an Analysis, naming its root and the window it was given.
    stub_const('AnalysisStandIn', Struct.new(:root_id, :window) do
      def with_window(range)
        self.class.new(root_id, range&.to_range)
      end
    end)
  end

  def at(minute)
    Time.utc(2032, 1, 1, 12) + (minute * 60)
  end

  # Created, then updated once for each minute after the first, at the
  # given minutes past the start.
  def article(minutes: [0, 1])
    record = FilterArticle.create!(title: 'Draft')
    minutes.drop(1).each_with_index { |_minute, index| record.update!(title: "Edit #{index}") }
    versions = FilterVersion.where(item_id: record.id).order(:id).to_a
    versions.zip(minutes) { |version, minute| version.update_columns(created_at: at(minute)) }
    [record, *versions]
  end

  def key(record)
    PaperTrailDiff::Endpoint.identity(record)
  end

  # Reads each record's current row again, as the adapter's loader does, and
  # only once for a batch.
  def live_loader
    read = false
    lambda do |records|
      raise 'the batch read its records twice' if read

      read = true
      loaded << records
      records.to_h { |record| [key(record), FilterArticle.find(record.id)] }
    end
  end

  def batch(records, within: nil, version_scope: nil, context: false)
    described_class.new(
      records, time_range: within && PaperTrailDiff::TimeRange.new(within),
               live_loader: live_loader, history_preparer: history_preparer,
               analyzer: analyzer, version_scope: version_scope, context_required: context
    )
  end

  def analyze(...)
    batch(...).call
  end

  it 'analyzes each record from its versions, keyed by its identity' do
    first, *first_versions = article
    second, *second_versions = article(minutes: [2, 3])

    result = analyze([first, second])

    expect(result).to eq(key(first) => AnalysisStandIn.new(first.id),
                         key(second) => AnalysisStandIn.new(second.id))
    expect(result).to be_frozen
    expect(analyzed.map { |record, plan, _window| [record, plan.versions] })
      .to eq([[first, first_versions], [second, second_versions]])
  end

  it 'reads the records again once, and prepares history from what it read' do
    first, = article
    second, = article

    analyze([first, second])

    expect(loaded).to eq([[first, second]])
    records, = prepared.sole
    expect(records).to eq([first, second])
    expect(records.map(&:object_id)).not_to include(first.object_id, second.object_id)
  end

  # A paginated array, for one, is an Array subclass.
  it 'takes any kind of array' do
    record, = article

    expect(analyze(Class.new(Array).new([record])).keys).to eq([key(record)])
  end

  it 'refuses records that are not an array, are not current records, or repeat' do
    first, created, = article
    unsaved = FilterArticle.new(title: 'Unsaved')
    feature = FilterFeature.create!(title: 'Feature')

    expect { analyze(FilterArticle.all) }
      .to raise_error(PaperTrailDiff::ConfigurationError, 'records: must be an array')
    expect { analyze([created]) }
      .to raise_error(PaperTrailDiff::InvalidEndpointError, /\Aexpected a record/)
    expect { analyze([unsaved]) }
      .to raise_error(PaperTrailDiff::InvalidEndpointError, /must be persisted/)
    [[first, FilterArticle.find(first.id)],
     [feature, feature.becomes(FilterArticle)]].each do |pair|
      expect { analyze(pair) }
        .to raise_error(PaperTrailDiff::ConfigurationError, 'records: identities must be unique')
    end
    expect(loaded).to eq([])
  end

  it 'checks the version scope as it is built' do
    expect { batch([], version_scope: :updates) }
      .to raise_error(PaperTrailDiff::ConfigurationError, 'version_scope: must respond to call')
  end

  it 'selects the versions the version scope keeps' do
    record, _created, updated = article

    analyze([record], version_scope: ->(versions) { versions.where(id: updated.id) })

    expect(analyzed.sole[1].mutations).to eq([updated])
  end

  it 'plans a window again over how far its transactions reach, and passes the window as asked' do
    record, _created, updated = article
    other, = article(minutes: [0, 2])
    reaches << [at(1), nil]

    result = analyze([record, other], within: at(1.25)..at(3))

    expect(analyzed.map { |root, plan, window| [root, plan.versions.first, window.to_range] })
      .to eq([[record, updated, at(1.25)..at(3)],
              [other, FilterVersion.where(item_id: other.id).order(:id).last, at(1.25)..at(3)]])
    expect(result.fetch(key(record)).window).to eq(at(1.25)..at(3))
  end

  # An activity view reports association changes in such a window, so it
  # needs the root's state there: the version after the window holds it.
  it 'reads a root with nothing in the window from the version after it when asked' do
    record, _created, _updated, after = article(minutes: [0, 1, 4])

    analyze([record], within: at(2)..at(3))
    analyze([record], within: at(2)..at(3), context: true)

    plan = analyzed.sole[1]
    expect(plan.reconstruction_versions).to eq([after])
    expect(plan.mutation?(after)).to be(false)
  end

  # Activity on associations replays every version, however few the scope
  # keeps, so that each step shows what its own change did.
  it 'replays every version the version scope leaves out when asked' do
    record, *versions = article(minutes: [0, 1, 2])

    analyze([record], version_scope: :none.to_proc, context: true)

    plan = analyzed.sole[1]
    expect([plan.reconstruction_versions, plan.mutations]).to eq([versions, []])
  end
end
