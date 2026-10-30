# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :scope_condition_items, force: true do |table|
    table.integer :owner_id
    table.integer :rank
    table.integer :status
    table.boolean :flag
    table.string :label
    table.text :note
    table.datetime :seen_at
    table.decimal :amount, precision: 10, scale: 2
  end
end

class ScopeConditionItem < ActiveRecord::Base
  enum :status, { draft: 0, live: 1 }
end

# The owner of each reflection under test; only reflections are read.
class ScopeConditionOwner < ActiveRecord::Base
  self.table_name = 'scope_condition_items'
end

RSpec.describe PaperTrailDiff::ScopeCondition do
  let(:table) { ScopeConditionItem.arel_table }

  def reflection(scope = nil, target: 'ScopeConditionItem', macro: :has_many, name: :items)
    options = { class_name: target, foreign_key: :owner_id }
    ScopeConditionOwner.public_send(macro, name, scope, **options)
    ScopeConditionOwner.reflect_on_association(name)
  end

  def build(scope = nil, **options)
    described_class.build(reflection(scope, **options))
  end

  def matches(condition, *rows)
    rows.map { |row| condition.matches?(row.transform_keys(&:to_s)) }
  end

  describe '.build' do
    it 'matches every record when nothing scopes the target' do
      expect(matches(build, {}, { 'rank' => nil })).to eq([true, true])
      expect(build).to be_frozen
    end

    it 'reads equality, IS NULL and their negations against stored values' do
      expect(matches(build(-> { where(rank: 3) }), { rank: 3 }, { rank: '3' }, { rank: 4 }, {}))
        .to eq([true, true, false, false])
      expect(matches(build(-> { where(rank: nil) }), { rank: nil }, { rank: 3 }))
        .to eq([true, false])
      expect(matches(build(-> { where.not(rank: 3) }), { rank: 4 }, { rank: 3 }, { rank: nil }))
        .to eq([true, false, false])
      expect(matches(build(-> { where.not(rank: nil) }), { rank: 3 }, { rank: nil }))
        .to eq([true, false])
    end

    it 'reads IN and NOT IN lists, which never match NULL' do
      expect(matches(build(-> { where(rank: [1, 2]) }), { rank: 2 }, { rank: 3 }, { rank: nil }))
        .to eq([true, false, false])
      expect(matches(build(lambda {
        where.not(rank: [1, 2])
      }), { rank: 3 }, { rank: 1 }, { rank: nil }))
        .to eq([true, false, false])
      expect(matches(build(-> { where(table[:rank].in([1, 2])) }), { rank: 1 }, { rank: 3 },
                     { rank: nil })).to eq([true, false, false])
      expect(matches(build(-> { where(table[:rank].not_in([1, 2])) }), { rank: 3 }, { rank: 2 },
                     { rank: nil })).to eq([true, false, false])
    end

    it 'reads a NOT IN list holding NULL as matching nothing, as SQL does' do
      expect(matches(build(lambda {
        where(table[:rank].not_in([1, nil]))
      }), { rank: 3 }, { rank: nil }))
        .to eq([false, false])
    end

    it 'reads empty lists as Active Record writes them: IN never, NOT IN always' do
      expect(matches(build(lambda {
        where(rank: [])
      }), { rank: 1 }, { rank: nil })).to eq([false, false])
      expect(matches(build(-> { where(table[:rank].in([])) }), { rank: 1 })).to eq([false])
      expect(matches(build(-> { where.not(rank: []) }), { rank: 1 }, { rank: nil }))
        .to eq([true, true])
      expect(matches(build(-> { where(table[:rank].not_in([])) }), { rank: 1 }, { rank: nil }))
        .to eq([true, true])
    end

    it 'combines conditions with AND, OR and grouping' do
      both = build(-> { where(rank: 1, flag: true) })
      expect(matches(both, { rank: 1, flag: true }, { rank: 1, flag: false },
                     { rank: 2, flag: true }, { rank: nil, flag: true }))
        .to eq([true, false, false, false])
      either = build(-> { where(rank: 1).or(where(flag: true)) })
      expect(matches(either, { rank: 1, flag: false }, { rank: 2, flag: true },
                     { rank: 2, flag: false })).to eq([true, true, false])
      expect(matches(build(-> { where(rank: [1, nil]) }), { rank: nil }, { rank: 1 }, { rank: 2 }))
        .to eq([true, true, false])
    end

    # SQL's NOT leaves an unknown comparison unknown, so a NULL that fails a
    # condition fails its negation too, where plain negation would admit it.
    it 'reads NOT as SQL does, leaving a comparison with NULL unknown' do
      expect(matches(build(-> { where.not(rank: [1, nil]) }), { rank: 2 }, { rank: 1 },
                     { rank: nil })).to eq([true, false, false])
      both = build(-> { where.not(rank: 1, flag: true) })
      expect(matches(both, { rank: 1, flag: false }, { rank: 1, flag: true },
                     { rank: nil, flag: true }, { rank: nil, flag: false }))
        .to eq([true, false, false, true])
      expect(matches(build(-> { where(table[:rank].eq(1).not) }), { rank: 2 }, { rank: 1 },
                     { rank: nil })).to eq([true, false, false])
      unknown = build(-> { where.not(rank: 1).or(where.not(flag: true)) })
      expect(matches(unknown, { rank: nil, flag: nil }, { rank: nil, flag: false }))
        .to eq([false, true])
      neither = build(-> { where(table[:rank].eq(1).or(table[:flag].eq(true)).not) })
      expect(matches(neither, { rank: nil, flag: false }, { rank: 2, flag: false }))
        .to eq([false, true])
    end

    it 'reads a default scope of the target together with the association scope' do
      stub_const('ScopeConditionDefaulted', Class.new(ScopeConditionItem))
      ScopeConditionDefaulted.class_eval { default_scope { where(flag: true) } }
      condition = build(-> { where(rank: 1) }, target: 'ScopeConditionDefaulted')

      expect(matches(condition, { rank: 1, flag: true }, { rank: 1, flag: false },
                     { rank: 2, flag: true })).to eq([true, false, false])
      expect(matches(build(target: 'ScopeConditionDefaulted'), { flag: true }, { flag: false }))
        .to eq([true, false])
    end

    it 'leaves out the type condition of a single-table subclass' do
      stub_const('ScopeConditionSubclass', Class.new(ScopeConditionItem))
      allow(ScopeConditionSubclass).to receive(:finder_needs_type_condition?).and_return(true)
      ScopeConditionSubclass.class_eval { default_scope { where(rank: 1) } }

      expect(matches(build(target: 'ScopeConditionSubclass'), { rank: 1 })).to eq([true])
    end

    it 'compares values cast as the column casts them, enums by what they store' do
      expect(matches(build(-> { where(status: :live) }), { status: 'live' }, { status: 1 },
                     { status: 'draft' })).to eq([true, true, false])
      expect(matches(build(-> { where(flag: false) }), { flag: false }, { flag: 0 }, { flag: nil }))
        .to eq([true, true, false])
    end

    # Column objects are frozen, so the columns are replaced through the model.
    def collation(value, sql_type: 'varchar')
      column = Struct.new(:collation, :sql_type).new(value, sql_type)
      columns = ScopeConditionItem.columns_hash.merge('label' => column, 'note' => column)
      allow(ScopeConditionItem).to receive(:columns_hash).and_return(columns)
    end

    it 'reads string columns only where the database compares strings exactly' do
      config = ScopeConditionItem.connection_db_config
      collation(nil)
      %w[sqlite3 postgresql].each do |adapter|
        allow(config).to receive(:adapter).and_return(adapter)
        expect(matches(build(-> { where(label: 'a') }), { label: 'a' }, { label: 'A' }))
          .to eq([true, false])
        expect(build(-> { where(note: 'a') })).not_to be_nil
      end
      %w[mysql2 trilogy sqlserver].each do |adapter|
        allow(config).to receive(:adapter).and_return(adapter)
        expect(build(-> { where(label: 'a') })).to be_nil
        expect(matches(build(-> { where(rank: 1) }), { rank: 1 })).to eq([true])
      end
      allow(config).to receive(:adapter).and_return('sqlite3')
      collation('NOCASE')
      expect(build(-> { where(label: 'a') })).to be_nil
      expect(build(-> { where(rank: 1) })).not_to be_nil
    end

    # citext compares without regard to case, and Active Record reads it as a
    # plain string.
    it 'leaves a PostgreSQL citext column unread' do
      allow(ScopeConditionItem.connection_db_config).to receive(:adapter).and_return('postgresql')
      collation(nil, sql_type: 'citext')

      expect(build(-> { where(label: 'a') })).to be_nil
      expect(matches(build(-> { where(label: nil) }), { label: nil }, { label: 'a' }))
        .to eq([true, false])
    end

    # Active Record before 7.2 wraps each bound value in a BindParam node.
    it 'reads a value wrapped in a bind parameter' do
      bound = lambda do
        type = ScopeConditionItem.type_for_attribute('rank')
        attribute = ActiveRecord::Relation::QueryAttribute.new('rank', 3, type)
        where(Arel::Nodes::Equality.new(table[:rank], Arel::Nodes::BindParam.new(attribute)))
      end
      expect(matches(build(bound), { rank: 3 }, { rank: 4 })).to eq([true, false])
    end

    # Before Rails 7.2 an OR node has a left and a right instead of children.
    it 'reads an OR node that has only a left and a right side' do
      stub_const('ScopeConditionBinaryOr', Struct.new(:left, :right))
      allow(ScopeConditionBinaryOr).to receive(:name).and_return('Arel::Nodes::Or')
      either = ScopeConditionBinaryOr.new(table[:rank].eq(1), table[:rank].eq(2))
      reader = described_class.const_get(:Reader).new(ScopeConditionItem)
      condition = described_class.new(ScopeConditionItem, reader.call(either))

      expect(matches(condition, { rank: 1 }, { rank: 2 }, { rank: 3 })).to eq([true, true, false])
    end

    it 'reads every side of an OR node that has more than two' do
      # Rails 7.1 has no Nary node to compare with.
      unless defined?(Arel::Nodes::Nary) && Arel::Nodes::Or < Arel::Nodes::Nary
        skip 'OR nodes have exactly two sides before Rails 7.2'
      end
      any = -> { where(Arel::Nodes::Or.new([1, 2, 3].map { |rank| table[:rank].eq(rank) })) }
      expect(matches(build(any), { rank: 3 }, { rank: 4 })).to eq([true, false])
    end

    # Whether a value is NULL compares alike on every type, as a soft-delete
    # scope's `deleted_at IS NULL` needs.
    it 'reads IS NULL and IS NOT NULL on a column of any type' do
      expect(matches(build(-> { where(seen_at: nil) }), { seen_at: nil },
                     { seen_at: Time.utc(2026) })).to eq([true, false])
      expect(matches(build(-> { where.not(amount: nil) }), { amount: nil }, { amount: 1 }))
        .to eq([false, true])
    end

    it 'declines column types whose values Ruby cannot compare as SQL does' do
      expect(build(-> { where(seen_at: Time.utc(2026)) })).to be_nil
      expect(build(-> { where.not(seen_at: Time.utc(2026)) })).to be_nil
      expect(build(-> { where(seen_at: [Time.utc(2026), Time.utc(2027)]) })).to be_nil
      expect(build(-> { where(amount: 1) })).to be_nil
      stub_const('ScopeConditionSerialized', Class.new(ScopeConditionItem))
      ScopeConditionSerialized.serialize :note, coder: YAML
      expect(build(-> { where(note: 'a') }, target: 'ScopeConditionSerialized')).to be_nil
      stub_const('ScopeConditionVirtual', Class.new(ScopeConditionItem))
      ScopeConditionVirtual.attribute :virtual_rank, :integer
      expect(build(-> { where(virtual_rank: 1) }, target: 'ScopeConditionVirtual')).to be_nil
      expect(build(-> { where(virtual_rank: nil) }, target: 'ScopeConditionVirtual')).to be_nil
    end

    it 'declines SQL strings, ranges, subqueries and other tables or columns' do
      [-> { where('rank = 1') }, -> { where(rank: 1..3) },
       -> { where(rank: ScopeConditionItem.select(:rank)) },
       -> { where(owner_id: ScopeConditionOwner.where(rank: 1).select(:id).arel) },
       -> { where(table[:rank].eq(table[:owner_id])) },
       -> { where(Arel::Nodes::Equality.new(Arel.sql('rank'), table[:rank].eq(1).right)) },
       -> { where(Arel::Nodes::Equality.new(Arel.sql('rank'), table[:rank].eq(nil).right)) },
       -> { where(Arel::Table.new(:scope_condition_items, as: 'aliased')[:rank].eq(1)) },
       -> { where(Arel::Table.new(:tracked_articles)[:id].eq(1)) },
       -> { where(rank: 2**70) }].each do |scope|
        expect(build(scope)).to be_nil
      end
    end

    it 'declines relation parts other than conditions, and a scope that takes the owner' do
      [-> { where(rank: 1).limit(1) }, -> { offset(1) }, -> { joins(:items) }, -> { distinct },
       -> { select(:id) }, -> { group(:rank) }, lambda { |owner|
                                                  where(rank: owner.rank)
                                                }].each do |scope|
        expect(build(scope)).to be_nil
      end
      expect(build(lambda {
        where(rank: 1).order(:id).readonly.strict_loading.extending
      })).not_to be_nil
      expect(build(-> { reorder(:id) })).not_to be_nil
    end

    # The ranking itself is ScopeRanking's; here only whether one applies.
    it 'ranks the records that meet its conditions by a limit, offset or has_one order' do
      rows = [{ id: 3, rank: 1 }, { id: 1, rank: 2 }, { id: 2, rank: 1 }].map do |row|
        Struct.new(:attributes).new(row.transform_keys(&:to_s))
      end
      ids = ->(condition) { condition.members(rows).map { |row| row.attributes.fetch('id') } }

      expect(ids.call(build(-> { where(rank: 1).order(:id).limit(1) }))).to eq([2])
      expect(ids.call(build(-> { order(id: :desc).offset(1) }))).to eq([2, 1])
      expect(ids.call(build(-> { order(:id) }, macro: :has_one, name: :item))).to eq([1, 2, 3])
      expect(ids.call(build(-> { where(rank: 1) }, macro: :has_one, name: :item))).to eq([3, 2])
      expect(ids.call(build(-> { order(:id) }))).to eq([3, 1, 2])
      expect(build(-> { order(:id) }, macro: :belongs_to, name: :owner_item)).not_to be_nil
      expect(build(-> { order(:id).limit(1) }, macro: :belongs_to, name: :owner_item)).to be_nil
      expect(build(-> { order(:label, :id).limit(1) })).to be_nil
    end

    # A has_many through keeps only its parts' conditions, so a part is read
    # unranked there; a has_one through orders by its parts and takes one.
    it 'reads a has_many through a ranked part, the part unranked, but no such has_one' do
      ScopeConditionItem.has_many :all_items, class_name: 'ScopeConditionItem',
                                              foreign_key: :owner_id
      ScopeConditionItem.belongs_to :parent_item, class_name: 'ScopeConditionItem',
                                                  foreign_key: :owner_id
      ScopeConditionOwner.has_many :first_items, -> { order(:id).limit(1) },
                                   class_name: 'ScopeConditionItem', foreign_key: :owner_id
      ScopeConditionOwner.has_one :lead_item, -> { order(:id) }, class_name: 'ScopeConditionItem',
                                                                 foreign_key: :owner_id
      ScopeConditionOwner.has_many :first_through, through: :first_items, source: :all_items
      ScopeConditionOwner.has_one :lead_parent, through: :lead_item, source: :parent_item
      reflection
      rows = [3, 1, 2].map { |id| Struct.new(:attributes).new({ 'id' => id }) }
      ids = ->(condition) { condition.members(rows).map { |row| row.attributes.fetch('id') } }

      through = ScopeConditionOwner.reflect_on_association(:first_through)
      expect(ids.call(described_class.build(through))).to eq([3, 1, 2])
      expect(ids.call(described_class.build(through.through_reflection, ranked: false)))
        .to eq([3, 1, 2])
      expect(ids.call(described_class.build(through.through_reflection))).to eq([1])
      expect(described_class.build(ScopeConditionOwner.reflect_on_association(:lead_parent)))
        .to be_nil
      expect(described_class.build(ScopeConditionOwner.reflect_on_association(:lead_parent),
                                   ranked: false)).not_to be_nil
    end

    it 'reads a polymorphic target with the class it is given' do
      polymorphic = ScopeConditionOwner.belongs_to :target, -> { where(rank: 1) },
                                                   polymorphic: true
      condition = described_class.build(ScopeConditionOwner.reflect_on_association(:target),
                                        ScopeConditionItem)
      expect(polymorphic).to be_a(Hash)
      expect(matches(condition, { rank: 1 }, { rank: 2 })).to eq([true, false])
    end
  end

  describe PaperTrailDiff::ScopeCondition::Cache do
    subject(:cache) { described_class.new }

    before do
      ScopeConditionOwner.has_many :ranked, -> { where(rank: 1) }, class_name: 'ScopeConditionItem',
                                                                   foreign_key: :owner_id
      ScopeConditionOwner.has_many :unread, -> { where('rank = 1') },
                                   class_name: 'ScopeConditionItem', foreign_key: :owner_id
      ScopeConditionOwner.belongs_to :target, -> { where(rank: 1) }, polymorphic: true
    end

    def reflection(name)
      ScopeConditionOwner.reflect_on_association(name)
    end

    it 'builds each condition once per reflection and target class, nil included' do
      allow(PaperTrailDiff::ScopeCondition).to receive(:build).and_call_original
      ranked = cache.call(reflection(:ranked))
      2.times { expect(cache.call(reflection(:ranked))).to equal(ranked) }
      2.times { expect(cache.call(reflection(:unread))).to be_nil }
      target = reflection(:target)
      item = cache.call(target, ScopeConditionItem)
      expect(item).to be_a(PaperTrailDiff::ScopeCondition)
      expect(cache.call(target, ScopeConditionItem)).to equal(item)
      expect(cache.call(target, ScopeConditionOwner)).not_to equal(item)

      unranked = cache.call(reflection(:ranked), ranked: false)
      expect(unranked).not_to equal(ranked)
      expect(cache.call(reflection(:ranked), ScopeConditionItem, ranked: false)).to equal(unranked)

      expect(PaperTrailDiff::ScopeCondition).to have_received(:build).exactly(5).times
      expect(PaperTrailDiff::ScopeCondition).to have_received(:build)
        .with(reflection(:ranked), ScopeConditionItem, ranked: true).once
    end

    it 'selects the records the scope admits, by their attributes' do
      records = [{ 'rank' => 1 }, { 'rank' => 2 }, { 'rank' => '1' }].map do |attributes|
        instance_double(ScopeConditionItem, attributes: attributes)
      end
      expect(cache.select(reflection(:ranked), records, ranked: true))
        .to eq([records[0], records[2]])
      expect(cache.select(reflection(:target), records, ScopeConditionItem, ranked: true))
        .to eq([records[0], records[2]])
    end

    it 'ranks the records it selects only when asked' do
      ScopeConditionOwner.has_many :first_ranked, -> { where(rank: 1).order(id: :desc).limit(1) },
                                   class_name: 'ScopeConditionItem', foreign_key: :owner_id
      records = [{ 'id' => 1, 'rank' => 1 }, { 'id' => 2, 'rank' => 1 }, { 'id' => 3, 'rank' => 2 }]
                .map { |attributes| instance_double(ScopeConditionItem, attributes: attributes) }
      expect([true, false].map do |ranked|
        cache.select(reflection(:first_ranked), records, ranked: ranked)
      end).to eq([[records[1]], records.first(2)])
    end
  end

  describe '.scoped_path?' do
    before do
      ScopeConditionOwner.has_many :plain_items, class_name: 'ScopeConditionItem',
                                                 foreign_key: :owner_id
      ScopeConditionOwner.has_many :ranked_items, -> { where(rank: 1) },
                                   class_name: 'ScopeConditionItem', foreign_key: :owner_id
      ScopeConditionOwner.belongs_to :plain_target, polymorphic: true
      ScopeConditionOwner.belongs_to :ranked_target, -> { where(rank: 1) }, polymorphic: true
      ScopeConditionOwner.has_many :plain_through, through: :plain_items, source: :ranked_items
      ScopeConditionOwner.has_many :through_ranked, through: :ranked_items, source: :plain_items
      ScopeConditionOwner.has_many :through_plain, through: :plain_items, source: :plain_items
      ScopeConditionItem.has_many :plain_items, class_name: 'ScopeConditionItem',
                                                foreign_key: :owner_id
      ScopeConditionItem.has_many :ranked_items, -> { where(rank: 1) },
                                  class_name: 'ScopeConditionItem', foreign_key: :owner_id
    end

    def scoped_path?(name)
      described_class.scoped_path?(ScopeConditionOwner.reflect_on_association(name))
    end

    it 'finds a scope on the reflection, its target or any reflection a through passes' do
      expect(%i[plain_items ranked_items plain_target ranked_target plain_through through_ranked
                through_plain].map { |name| scoped_path?(name) })
        .to eq([false, true, false, true, true, true, false])
    end

    it 'finds the default scope of the target' do
      stub_const('ScopeConditionDefaulted', Class.new(ScopeConditionItem))
      ScopeConditionDefaulted.class_eval { default_scope { where(flag: true) } }
      ScopeConditionOwner.has_many :defaulted, class_name: 'ScopeConditionDefaulted',
                                               foreign_key: :owner_id
      expect(scoped_path?(:defaulted)).to be(true)
    end
  end

  describe '.ranked_parts?' do
    before do
      ScopeConditionOwner.has_many :all_items, class_name: 'ScopeConditionItem',
                                               foreign_key: :owner_id
      ScopeConditionOwner.has_many :first_items, -> { order(:id).limit(1) },
                                   class_name: 'ScopeConditionItem', foreign_key: :owner_id
      ScopeConditionOwner.has_one :lead_item, -> { order(:id) }, class_name: 'ScopeConditionItem',
                                                                 foreign_key: :owner_id
      ScopeConditionOwner.belongs_to :any_target, polymorphic: true, foreign_key: :owner_id,
                                                  foreign_type: :label
      ScopeConditionOwner.has_many :own_items, ->(owner) { where(rank: owner.rank) },
                                   class_name: 'ScopeConditionItem', foreign_key: :owner_id
      ScopeConditionItem.has_many :all_items, class_name: 'ScopeConditionItem',
                                              foreign_key: :owner_id
      ScopeConditionItem.has_many :later_items, -> { order(:id).offset(1) },
                                  class_name: 'ScopeConditionItem', foreign_key: :owner_id
      ScopeConditionItem.belongs_to :any_target, polymorphic: true, foreign_key: :owner_id,
                                                 foreign_type: :label
      { plain_through: %i[all_items all_items], first_through: %i[first_items all_items],
        lead_through: %i[lead_item all_items], later_through: %i[all_items later_items],
        nested_through: %i[first_through all_items], plain_nested: %i[plain_through all_items],
        typed_through: %i[all_items any_target],
        owner_through: %i[own_items all_items] }.each do |name, (through, source)|
        options = name == :typed_through ? { source_type: 'ScopeConditionItem' } : {}
        ScopeConditionOwner.has_many name, through: through, source: source, **options
      end
    end

    def ranked_parts?(name)
      described_class.ranked_parts?(ScopeConditionOwner.reflect_on_association(name))
    end

    it 'finds a limit, offset or has_one order on any part a through passes' do
      expect(%i[first_through lead_through later_through nested_through].map do |name|
        ranked_parts?(name)
      end).to eq([true, true, true, true])
      expect(%i[first_items plain_through plain_nested typed_through owner_through].map do |name|
        ranked_parts?(name)
      end).to eq([false, false, false, false, false])
    end
  end

  # A has_many through keeps only its parts' conditions.
  describe '.for_relation' do
    def relation_matches(relation, *rows)
      condition = described_class.for_relation(relation, relation.model)
      rows.map { |row| condition.matches?(row.transform_keys(&:to_s)) }
    end

    it "reads a relation's conditions and default scope, leaving out its page and loading" do
      relation = ScopeConditionItem.where(rank: 1).or(ScopeConditionItem.where(flag: true))
      expect(relation_matches(relation, { rank: 1 }, { flag: true }, { rank: 2, flag: false }))
        .to eq([true, true, false])
      expect(relation_matches(ScopeConditionItem.all, { rank: nil })).to eq([true])

      stub_const('ScopeConditionDefaulted', Class.new(ScopeConditionItem))
      ScopeConditionDefaulted.class_eval { default_scope { where(flag: true) } }
      paged = ScopeConditionDefaulted.where(rank: 1).order(:id).limit(1).offset(1)
                                     .includes(:none).preload(:none).select(:id).distinct
      expect(relation_matches(paged, { rank: 1, flag: true }, { rank: 1, flag: false }))
        .to eq([true, false])
    end

    it 'leaves out the type condition of a single-table subclass' do
      stub_const('ScopeConditionKind', Class.new(ScopeConditionItem))
      allow(ScopeConditionKind).to receive(:finder_needs_type_condition?).and_return(true)

      expect(relation_matches(ScopeConditionKind.where(rank: 1), { rank: 1 })).to eq([true])
    end

    it 'declines a relation that joins, groups, or that it cannot read' do
      [ScopeConditionItem.joins('JOIN tracked_articles ON 1 = 1'), ScopeConditionItem.group(:rank),
       ScopeConditionItem.where('rank = 1'), ScopeConditionItem.where(seen_at: Time.utc(2026)),
       ScopeConditionItem.having('COUNT(*) > 1'), ScopeConditionItem.from('scope_condition_items'),
       ScopeConditionItem.lock]
        .each do |relation|
          expect(described_class.for_relation(relation, relation.model)).to be_nil
        end
    end
  end

  describe '.ranked_through?' do
    before do
      ScopeConditionOwner.has_one :lead_item, -> { order(:id) }, class_name: 'ScopeConditionItem',
                                                                 foreign_key: :owner_id
      ScopeConditionOwner.has_one :any_item, class_name: 'ScopeConditionItem',
                                             foreign_key: :owner_id
      ScopeConditionItem.belongs_to :parent_item, class_name: 'ScopeConditionItem',
                                                  foreign_key: :owner_id
      ScopeConditionItem.has_many :all_items, class_name: 'ScopeConditionItem',
                                              foreign_key: :owner_id
      ScopeConditionOwner.has_one :lead_parent, through: :lead_item, source: :parent_item
      ScopeConditionOwner.has_one :any_parent, through: :any_item, source: :parent_item
      ScopeConditionOwner.has_many :lead_children, through: :lead_item, source: :all_items
    end

    it 'finds a ranked part only under a has_one through' do
      expect(%i[lead_parent any_parent lead_children lead_item].map do |name|
        described_class.ranked_through?(ScopeConditionOwner.reflect_on_association(name))
      end).to eq([true, false, false, false])
    end
  end
end
