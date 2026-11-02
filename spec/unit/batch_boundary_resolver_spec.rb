# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::BatchBoundaryResolver do
  let(:start_time) { Time.utc(2032, 1, 1, 12) }

  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
    FilterEvent.delete_all
  end

  # Created, then updated twice, at the given minutes past the start.
  def history(model = FilterArticle, minutes: [0, 1, 2])
    record = model.create!(title: 'Draft')
    %w[Review Final].each { |title| record.update!(title: title) }
    versions = FilterVersion.where(item_type: 'FilterArticle', item_id: record.id).order(:id).to_a
    versions.zip(minutes) do |version, minute|
      version.update_columns(created_at: start_time + (minute * 60))
    end
    [record, *versions]
  end

  def resolve(*pairs)
    described_class.new(pairs).call
  end

  # The statements a block runs, other than Active Record's schema reads.
  def statements(&)
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &)
    queries
  end

  it 'tells a symbol from an endpoint' do
    expect([:first, 'first', nil].map { |value| described_class.symbolic?(value) })
      .to eq([true, false, false])
  end

  it 'returns pairs without a symbol as they are, reading nothing' do
    record, created, = history
    pairs = [[created, record]]

    expect(statements { expect(described_class.new(pairs).call).to equal(pairs) }).to eq([])
  end

  it "resolves :first to the record's earliest version, at either end of a pair" do
    record, created, = history
    other, other_created, = history(minutes: [3, 4, 5])

    expect(resolve([:first, record], [other, :first]))
      .to eq([[created, record], [other, other_created]])
  end

  it 'resolves :first beside a version of the record, or of a subclass' do
    _record, created, updated = history
    feature, feature_created, = history(FilterFeature, minutes: [3, 4, 5])

    expect(resolve([:first, updated], [:first, feature]))
      .to eq([[created, updated], [feature_created, feature]])
  end

  # Without ORDER BY, a database returns rows in any order; PostgreSQL
  # returns a row last once it is updated.
  it 'reads the earliest version by time, breaking a tie by id, in any order read' do
    record, _created, reviewed, = history(minutes: [2, 0, 0])
    reversed = ->(original, *args) { original.call(*args).order(id: :desc) }
    allow(PaperTrailDiff::VersionQuery).to receive(:for_items).and_wrap_original(&reversed)

    expect(resolve([:first, record])).to eq([[reviewed, record]])
  end

  it 'reads only the earliest version of each record' do
    record, = history
    loaded = 0
    counter = lambda do |*, payload|
      loaded += payload[:record_count] if payload[:class_name] == 'FilterVersion'
    end

    ActiveSupport::Notifications.subscribed(counter, 'instantiation.active_record') do
      resolve([:first, record])
    end

    expect(loaded).to eq(1)
  end

  it 'reads one statement for each model class' do
    first, = history
    second, = history
    event = FilterEvent.create!(status: :draft)

    found = statements { resolve([:first, first], [:first, second], [:first, event]) }

    expect(found.length).to eq(2)
  end

  # So the caller decides what an absent history means.
  it 'leaves :first in place for a record with no history, or a model that is gone' do
    record, = history
    FilterVersion.delete_all
    FilterVersion.insert({ item_type: 'RemovedModel', item_id: record.id, event: 'create',
                           created_at: start_time })
    gone = FilterVersion.sole

    expect(resolve([:first, record], [:first, gone])).to eq([[:first, record], [:first, gone]])
  end

  it 'refuses :last, any other symbol, and a :first nothing names a record for' do
    record, = history

    expect { resolve([:last, record]) }
      .to raise_error(PaperTrailDiff::ConfigurationError, PaperTrailDiff::TimelineRange::LAST_REMOVED)
    expect { resolve([:latest, record]) }
      .to raise_error(PaperTrailDiff::ConfigurationError,
                      'unsupported boundary: :latest; use :first, a version, or a record')
    [%i[first first], [:first, nil], [:first, 'a title']].each do |pair|
      expect { resolve(pair) }
        .to raise_error(PaperTrailDiff::ConfigurationError,
                        'a :first endpoint needs the other endpoint to name a record')
    end
  end
end
