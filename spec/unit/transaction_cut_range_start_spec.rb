# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::TransactionCut, '.range_start' do
  let(:noon) { Time.utc(2032, 1, 1, 12) }

  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  # One article's versions at the given minutes past noon, in the given
  # transactions. The numbers are offset past any version id, since a
  # version whose id is its number is where that transaction began (see
  # TransactionAnchors).
  def versions(*minutes, transactions: [])
    article = FilterArticle.create!(title: 'Draft')
    minutes.drop(1).each_with_index { |_, index| article.update!(title: "Edit #{index}") }
    rows = FilterVersion.where(item_id: article.id).order(:id).to_a
    rows.zip(minutes, transactions).map do |version, minute, transaction|
      version.update_columns(created_at: noon + (minute * 60),
                             transaction_id: transaction&.+(10_000))
      version
    end
  end

  # The first version stands in for a child's, saved earlier in the
  # transaction of the root's first version in range, as the update behind a
  # touch: true parent version is.
  it "moves the start back to the earliest version of each root's first transaction" do
    child, = versions(0, transactions: [7])
    earlier, root, later = versions(1, 3, 4, transactions: [5, 7, 9])

    expect(described_class.range_start([later, root, earlier], root.created_at))
      .to eq(child.created_at)
  end

  it "finds each root's first version in range by time, not by id" do
    child, = versions(0, transactions: [7])
    later, first = versions(4, 3, transactions: [9, 7])

    expect(described_class.range_start([later, first], noon + 120))
      .to eq(child.created_at)
  end

  it 'reads the first transaction of every root' do
    child, = versions(0, transactions: [8])
    first_root, = versions(2, transactions: [7])
    second_root, = versions(3, transactions: [8])

    expect(described_class.range_start([first_root, second_root], noon + 120))
      .to eq(child.created_at)
  end

  it 'reads only the first transaction of each root at or after the start' do
    versions(0, transactions: [9])
    root, later = versions(2, 3, transactions: [7, 9])

    expect(described_class.range_start([root, later], noon + 120)).to eq(noon + 120)
  end

  it 'keeps the start when no transaction opens before it' do
    early, late = versions(0, 2)
    root, = versions(2, transactions: [7])

    expect(described_class.range_start([early, late], noon + 60)).to eq(noon + 60)
    expect(described_class.range_start([root], noon + 90)).to eq(noon + 90)
    expect(described_class.range_start([], noon)).to eq(noon)
    expect(described_class.range_start([early, late], nil)).to be_nil
  end

  it 'keeps the start when the transaction left no versions to read' do
    root, = versions(1, transactions: [7])
    FilterVersion.delete_all

    expect(described_class.range_start([root], noon)).to eq(noon)
  end

  # The earliest start is in the second of four slices, and the last slice
  # reads nothing.
  it 'reads the transactions in slices, taking the earliest start of any' do
    stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 2)
    first_root, = versions(2, transactions: [7])
    second_root, = versions(3, transactions: [8])
    gone, = versions(4, transactions: [6])
    child, = versions(0, transactions: [9])
    third_root, = versions(5, transactions: [9])
    fourth_root, = versions(6, transactions: [10])
    gone_alone, = versions(7, transactions: [5])
    gone_too, = versions(8, transactions: [4])
    [gone, gone_alone, gone_too].each(&:delete)
    roots = [first_root, second_root, gone, third_root, fourth_root, gone_alone, gone_too]
    statements = []
    count = ->(*, payload) { statements << payload[:sql] if payload[:sql].include?('MIN(') }

    start = ActiveSupport::Notifications.subscribed(count, 'sql.active_record') do
      described_class.range_start(roots, noon + 120)
    end

    expect(start).to eq(child.created_at)
    expect(statements.length).to eq(4)
  end
end
