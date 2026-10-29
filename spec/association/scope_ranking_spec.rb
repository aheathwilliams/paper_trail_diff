# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :scope_ranking_items, force: true do |table|
    table.integer :owner_id
    table.integer :rank
    table.integer :level, null: false, default: 0
    table.boolean :flag, null: false, default: false
    table.integer :status, null: false, default: 0
    table.string :kind, null: false, default: 'a'
    table.string :label
    table.datetime :seen_at
    table.datetime :ms_at, precision: 3
    table.datetime :loose_at, precision: nil
    table.datetime :second_at, precision: 0
    table.time :starts_at, precision: 6
    table.decimal :amount, precision: 10, scale: 2
    table.date :due_on
  end
end

class ScopeRankingItem < ActiveRecord::Base
  enum :status, { draft: 0, live: 1 }
  enum :kind, { first: 'a', second: 'b' }, prefix: true
  has_many :children, class_name: 'ScopeRankingItem', foreign_key: :owner_id
end

# The owner of each reflection under test; only reflections are read.
class ScopeRankingOwner < ActiveRecord::Base
  self.table_name = 'scope_ranking_items'
  has_many :items, class_name: 'ScopeRankingItem', foreign_key: :owner_id
end

RSpec.describe PaperTrailDiff::ScopeRanking do
  let(:table) { ScopeRankingItem.arel_table }

  def reflection(scope, macro: :has_many, name: :ranked, **options)
    ScopeRankingOwner.public_send(macro, name, scope, class_name: 'ScopeRankingItem',
                                                      foreign_key: :owner_id, **options)
    ScopeRankingOwner.reflect_on_association(name)
  end

  def relation(scope)
    ScopeRankingItem.default_scoped.instance_exec(&scope)
  end

  def build(scope, **options)
    described_class.build(relation(scope), reflection(scope, **options), ScopeRankingItem)
  end

  def row(**attributes)
    Struct.new(:attributes).new(attributes.transform_keys(&:to_s))
  end

  def ranked(scope, rows, **options)
    build(scope, **options).call(rows).map { |ranked_row| ranked_row.attributes.fetch('id') }
  end

  def with_adapter(name)
    config = ScopeRankingItem.connection_db_config
    allow(config).to receive(:adapter).and_return(name)
    yield
  end

  # Mutant runs only the examples whose description names the mutated method
  # or, failing that, the class, so these sit at the class level to check
  # every method together.
  it 'ranks by a limit, an offset, or the order of a has_one' do
    ranks = lambda do |scope, macro = :has_many|
      described_class.ranks?(relation(scope), reflection(scope, macro: macro, name: :"r#{macro}"))
    end

    expect([ranks.call(-> { limit(1) }), ranks.call(-> { offset(1) }),
            ranks.call(-> { order(:id) }, :has_one)]).to eq([true, true, true])
    expect([ranks.call(-> { order(:id) }), ranks.call(-> { where(rank: 1) }, :has_one),
            ranks.call(-> { order(:id) }, :belongs_to)]).to eq([false, false, false])
  end

  it 'reads an order made total by the primary key' do
    expect(build(-> { order(:rank, :id).limit(2) })).to be_frozen
    expect(build(-> { order(:level, :id, :label).limit(2) })).not_to be_nil
    expect(build(-> { order(:rank).limit(2) })).to be_nil
    expect(build(-> { limit(2) })).to be_nil
  end

  it 'reads integer, boolean, integer enum, date and exact datetime columns, and no others' do
    %i[rank level flag status due_on seen_at ms_at].each do |key|
      expect(build(-> { order(key, :id).limit(1) })).not_to be_nil
    end
    %i[label kind loose_at starts_at amount].each do |key|
      expect(build(-> { order(key, :id).limit(1) })).to be_nil
    end
    # Active Record writes `order(:virtual_rank)` as SQL, so the attribute is
    # named through Arel to reach a key that is no column.
    stub_const('ScopeRankingVirtual', Class.new(ScopeRankingItem))
    ScopeRankingVirtual.attribute :virtual_rank, :integer
    virtual = ScopeRankingVirtual.order(ScopeRankingVirtual.arel_table[:virtual_rank].asc, :id)
    expect(described_class.build(virtual.limit(1), reflection(nil), ScopeRankingVirtual)).to be_nil
  end

  it 'reads plain ascending and descending keys on the record’s own table only' do
    other = Arel::Table.new(:scope_ranking_items, as: 'other')
    [-> { order('id').limit(1) },
     -> { order(table[:id].asc.nulls_first).limit(1) },
     -> { order(Arel.sql('id').asc).limit(1) },
     -> { in_order_of(:id, [2, 1]).order(:id).limit(1) },
     -> { order(other[:id].asc).limit(1) },
     -> { order(TrackedComment.arel_table[:id].asc).limit(1) },
     -> { order(Arel.sql('id')).limit(1) }].each do |scope|
      expect(build(scope)).to be_nil
    end
    expect(build(-> { order(table[:id].desc).limit(1) })).not_to be_nil
  end

  it 'reads a has_many, through or not, or a direct has_one, with an integer offset' do
    expect(build(-> { order(:id).offset(1) }, macro: :has_one, name: :second)).not_to be_nil
    expect(build(-> { order(:id).limit(1) }, macro: :belongs_to, name: :owner_item)).to be_nil
    ScopeRankingOwner.has_many :ranked_through, -> { order(:id).limit(1) },
                               through: :items, source: :children
    ScopeRankingOwner.has_one :lead_item, -> { order(:id) }, class_name: 'ScopeRankingItem',
                                                             foreign_key: :owner_id
    ScopeRankingItem.belongs_to :parent, class_name: 'ScopeRankingItem', foreign_key: :owner_id
    ScopeRankingOwner.has_one :ranked_parent, -> { order(:id) }, through: :lead_item,
                                                                 source: :parent
    expect(%i[ranked_through ranked_parent].map do |name|
      described_class.build(relation(-> { order(:id).limit(1) }),
                            ScopeRankingOwner.reflect_on_association(name), ScopeRankingItem)
    end.map(&:nil?)).to eq([false, true])
    expect(build(-> { order(:id).offset(Arel.sql('1')) })).to be_nil
    expect(build(-> { order(:id).offset('1') })).to be_nil
  end

  # JSON history keeps milliseconds by default, and local times repeat an hour.
  it 'reads a datetime only at a precision history keeps, stored in UTC' do
    allow(PaperTrailDiff::StoredTimePrecision).to receive(:digits).and_return(3)
    expect(%i[seen_at ms_at second_at].map { |key| build(-> { order(key, :id).limit(1) }) }
             .map(&:nil?)).to eq([true, false, false])
    allow(PaperTrailDiff::StoredTimePrecision).to receive(:digits).and_return(nil)
    allow(ActiveRecord).to receive(:default_timezone).and_return(:local)
    expect(build(-> { order(:ms_at, :id).limit(1) })).to be_nil
    expect(build(-> { order(:due_on, :id).limit(1) })).not_to be_nil
    expect(PaperTrailDiff::StoredTimePrecision).to have_received(:digits).with(ScopeRankingItem)
                                                                         .at_least(:once)
  end

  it 'reads only an adapter whose NULL placement it knows' do
    with_adapter('oracle') do
      expect(build(-> { order(:level, :id).limit(1) })).to be_nil
    end
    %w[postgresql sqlite3 mysql2 trilogy sqlserver].each do |adapter|
      with_adapter(adapter) { expect(build(-> { order(:rank, :id).limit(1) })).not_to be_nil }
    end
  end

  describe 'with rows' do
    let(:rows) do
      [row(id: 4, rank: 2, flag: true, status: 'draft'),
       row(id: 1, rank: nil, flag: false, status: 'live'),
       row(id: 3, rank: 2, flag: false, status: 'live'),
       row(id: 2, rank: 1, flag: true, status: 'draft'),
       row(id: 5, flag: true, status: 'draft')]
    end

    it 'ranks by each key in turn, then skips the offset and keeps the limit' do
      expect(ranked(-> { order(:id) }, rows, macro: :has_one, name: :lead)).to eq([1, 2, 3, 4, 5])
      expect(ranked(-> { order(id: :desc).offset(1) }, rows)).to eq([4, 3, 2, 1])
      expect(ranked(-> { order(:id).offset(1).limit(2) }, rows)).to eq([2, 3])
      expect(ranked(-> { order(:flag, :id).limit(3) }, rows)).to eq([1, 3, 2])
      expect(ranked(-> { order(flag: :desc, status: :desc, id: :asc).limit(2) }, rows))
        .to eq([2, 4])
      expect(ranked(-> { order(:status, id: :desc).limit(9) }, rows)).to eq([5, 4, 2, 3, 1])
    end

    # The last row holds no rank at all, as a version saved before the column.
    it 'places NULL as the adapter does, and reverses it in a descending order' do
      with_adapter('postgresql') do
        expect(ranked(-> { order(:rank, :id).limit(9) }, rows)).to eq([2, 3, 4, 1, 5])
        expect(ranked(-> { order(rank: :desc, id: :asc).limit(9) }, rows)).to eq([1, 5, 3, 4, 2])
      end
      with_adapter('mysql2') do
        expect(ranked(-> { order(:rank, :id).limit(9) }, rows)).to eq([1, 5, 2, 3, 4])
        expect(ranked(-> { order(rank: :desc, id: :asc).limit(9) }, rows)).to eq([3, 4, 2, 1, 5])
      end
    end

    it 'ranks datetimes to the microsecond and dates by day, either way' do
      at = Time.utc(2026, 1, 1, 12)
      times = [row(id: 1, seen_at: at + Rational(2, 1_000_000), due_on: Date.new(2026, 1, 3)),
               row(id: 2, seen_at: at, due_on: Date.new(2026, 1, 2)),
               row(id: 3, seen_at: at + Rational(1, 1_000_000), due_on: Date.new(2026, 1, 2)),
               row(id: 4, seen_at: at - 86_400, due_on: nil)]
      expect(ranked(-> { order(seen_at: :desc, id: :asc).limit(9) }, times)).to eq([1, 3, 2, 4])
      expect(ranked(-> { order(:due_on, :id).limit(9) }, times)).to eq([4, 2, 3, 1])
      expect(ranked(-> { order(due_on: :desc, id: :desc).limit(3) }, times)).to eq([1, 3, 2])
    end

    it 'compares the values the database stores, as the key’s type casts them' do
      typed = [row(id: 1, rank: '10'), row(id: 2, rank: '9'), row(id: 3, rank: 9)]
      expect(ranked(-> { order(:rank, :id).limit(2) }, typed)).to eq([2, 3])
    end
  end
end
