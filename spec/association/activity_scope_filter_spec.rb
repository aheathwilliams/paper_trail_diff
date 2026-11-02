# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe PaperTrailDiff::ActivityScopeFilter do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
  end

  let(:alice) { ->(versions) { versions.where(whodunnit: 'alice') } }

  def statements(&block)
    count = 0
    callback = lambda do |*, payload|
      count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    count
  end

  # The article's creation, a transaction alice and bob each saved a version
  # in, and one only bob did. A `PaperTrail.request` block would restore the
  # transaction PT-AT records when it ends, so the author is assigned.
  def history
    article = TrackedArticle.create!(title: 'Draft')
    TrackedArticle.transaction do
      PaperTrail.request.whodunnit = 'alice'
      article.comments.create!(body: 'by alice')
      PaperTrail.request.whodunnit = 'bob'
      article.update!(title: 'Titled')
    end
    article.update!(title: 'Retitled')
    PaperTrail::Version.order(:id).to_a
  ensure
    PaperTrail.request.whodunnit = nil
  end

  def kept(filter, versions)
    versions.map { |version| filter.kept?(version) }
  end

  it 'keeps every version of a transaction in which the filter keeps one, of any record' do
    versions = history
    filter = described_class.new(alice)

    filter.prepare(nil, versions)

    expect(versions.map(&:whodunnit)).to eq([nil, 'alice', 'bob', 'bob'])
    expect(kept(filter, versions)).to eq([false, true, true, false])
  end

  it 'keeps a version saved outside a transaction only when the filter keeps it' do
    versions = history
    PaperTrail::Version.update_all(transaction_id: nil)
    loose = PaperTrail::Version.order(:id).to_a
    filter = described_class.new(alice)

    read = statements { filter.prepare(nil, loose) }

    expect(kept(filter, loose)).to eq([false, true, false, false])
    expect(loose.map(&:id)).to eq(versions.map(&:id))
    expect(read).to eq(1)
  end

  # Its versions were saved in three transactions, one of them twice.
  it 'reads a history once, in one statement per slice, and every version it holds' do
    versions = history
    prepared = instance_double(PaperTrailDiff::PreparedHistory, versions: versions)
    filter = described_class.new(alice)
    stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 1)

    first = statements { filter.prepare(prepared, []) }
    again = statements { filter.prepare(prepared, versions) }

    expect([first, again]).to eq([3, 0])
    expect(prepared).to have_received(:versions).once
    expect(kept(filter, versions)).to eq([false, true, true, false])
  end

  it 'reads each history it is given once' do
    versions = history
    first = instance_double(PaperTrailDiff::PreparedHistory, versions: versions.first(2))
    second = instance_double(PaperTrailDiff::PreparedHistory, versions: versions.last(2))
    filter = described_class.new(alice)

    reads = [first, second, first, second].map do |prepared|
      statements { filter.prepare(prepared, []) }
    end

    expect(reads).to eq([1, 1, 0, 0])
    expect(kept(filter, versions)).to eq([false, true, true, false])
  end

  # One statement for each of the history's two transactions, and one for
  # the only transaction of the events' versions it does not hold.
  it 'reads the versions a history does not hold, and only those' do
    versions = history
    prepared = instance_double(PaperTrailDiff::PreparedHistory, versions: versions.first(2))
    other = instance_double(PaperTrailDiff::PreparedHistory, versions: versions)
    filter = described_class.new(alice)
    stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 1)

    first = statements { filter.prepare(prepared, versions.last(2)) }
    held = statements { filter.prepare(other, versions) }

    expect([first, held]).to eq([3, 0])
    expect(kept(filter, versions)).to eq([false, true, true, false])
  end

  it 'answers only for the versions it read, though the filter keeps others' do
    versions = history
    filter = described_class.new(alice)
    filter.prepare(nil, versions.first(1))

    expect { filter.kept?(versions.fetch(1)) }.to raise_error(KeyError)
  end
end
