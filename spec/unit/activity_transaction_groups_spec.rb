# frozen_string_literal: true

RSpec.describe PaperTrailDiff::ActivityTransactionGroups do
  # Two version tables, each numbering its own transactions.
  before do
    stub_const('GroupsVersion', Struct.new(:id, :transaction_id))
    stub_const('GroupsOtherVersion', Struct.new(:id, :transaction_id))
  end

  def event(id, transaction_id, branches: ['comments'], table: GroupsVersion)
    PaperTrailDiff::ActivityEvent.new(version: table.new(id, transaction_id), branches: branches)
  end

  describe '.before_closing' do
    it "leaves out the closing transaction's descendant events, keeping its root's" do
      root = event(1, 7, branches: nil)
      other_transaction = event(3, 8)
      no_transaction = event(4, nil)
      other_table = event(5, 7, table: GroupsOtherVersion)

      kept = described_class.before_closing(
        [root, event(2, 7), other_transaction, no_transaction, other_table], GroupsVersion.new(9, 7)
      )

      expect(kept).to eq([root, other_transaction, no_transaction, other_table])
      expect(kept).to be_frozen
    end

    it 'keeps every event when the range ends at a time or outside a transaction' do
      events = [event(1, 7)]

      expect(described_class.before_closing(events, Time.utc(2032))).to equal(events)
      expect(described_class.before_closing(events, GroupsVersion.new(9, nil))).to equal(events)
    end
  end

  describe '#events_for' do
    it "gives the events of an event's transaction, in the order given" do
      first = event(1, 7)
      apart = event(2, 8)
      last = event(3, 7)
      groups = described_class.new([first, apart, last, event(4, 7, table: GroupsOtherVersion)])

      expect(groups.events_for(last)).to eq([first, last])
      expect(groups.events_for(apart)).to eq([apart])
    end
  end

  describe '#branches_for' do
    it 'gives each event of a transaction the branches of all its events' do
      comment = event(1, 7, branches: ['comments'])
      author = event(2, 7, branches: ['author'])
      tag = event(3, 7, branches: %w[tags comments])
      alone = event(4, 8, branches: ['tags'])
      groups = described_class.new([comment, author, tag, alone])

      expect([comment, author, alone].map { |each| groups.branches_for(each) })
        .to eq([%w[author comments tags], %w[author comments tags], ['tags']])
      expect(groups.branches_for(comment)).to be_frozen
    end

    it "reads a transaction holding a root event as the root's" do
      groups = described_class.new([event(1, 7, branches: nil), event(2, 7)])

      expect(groups.branches_for(event(2, 7))).to be_nil
    end

    it 'reads an event outside a transaction, or in one it was not given, by its own branches' do
      groups = described_class.new([event(1, 7), event(2, nil)])

      expect(groups.branches_for(event(2, nil, branches: ['tags']))).to eq(['tags'])
      expect(groups.branches_for(event(3, 9, branches: ['author']))).to eq(['author'])
    end

    it 'tells transactions numbered alike in two version tables apart' do
      groups = described_class.new([event(1, 7, branches: nil)])

      expect(groups.branches_for(event(1, 7))).to be_nil
      expect(groups.branches_for(event(1, 7, table: GroupsOtherVersion))).to eq(['comments'])
    end
  end

  describe '#isolated?' do
    it 'tells an event alone in its transaction, or outside one, from one that shares it' do
      shared = [event(1, 7), event(2, 7)]
      alone = event(3, 8)
      groups = described_class.new([*shared, alone])

      asked = [*shared, alone, event(5, nil), event(6, 10)]

      expect(asked.map { |each| groups.isolated?(each) })
        .to eq([false, false, true, true, false])
    end
  end

  describe '#shared?' do
    it 'tells two events of one transaction from those of another or of none' do
      groups = described_class.new([event(1, 7), event(2, 7), event(3, 8)])

      pairs = [
        [event(1, 7), event(2, 7)], [event(2, 7), event(3, 8)], [event(5, nil), event(6, nil)],
        [event(1, 7), event(7, 7, table: GroupsOtherVersion)]
      ]

      expect(pairs.map { |left, right| groups.shared?(left, right) })
        .to eq([true, false, false, false])
    end
  end
end
