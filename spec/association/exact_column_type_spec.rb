# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :exact_column_items, force: true do |table|
    table.integer :rank
    table.integer :status
    table.boolean :flag
    table.string :label
    table.date :due_on
    table.datetime :seen_at
    table.decimal :amount, precision: 10, scale: 2
  end
end

class ExactColumnItem < ActiveRecord::Base
  enum :status, { draft: 0, live: 1 }
end

RSpec.describe PaperTrailDiff::ExactColumnType do
  def kind(name, model = ExactColumnItem)
    described_class.kind(model, name)
  end

  # Column objects are frozen, so the columns are replaced through the model.
  def columns(adapter, collation: nil, **sql_types)
    allow(ExactColumnItem.connection_db_config).to receive(:adapter).and_return(adapter)
    replaced = sql_types.to_h do |name, sql_type|
      [name.to_s, Struct.new(:collation, :sql_type).new(collation, sql_type)]
    end
    allow(ExactColumnItem).to receive(:columns_hash)
      .and_return(ExactColumnItem.columns_hash.merge(replaced))
  end

  def kinds(adapter, collation: nil, **sql_types)
    columns(adapter, collation: collation, **sql_types)
    sql_types.keys.map { |name| kind(name.to_s) }
  end

  describe '.kind' do
    it 'reads the kind each adapter lists for a column’s SQL type' do
      expect(kinds('sqlite3', rank: 'INTEGER', flag: 'boolean', label: 'varchar(20)',
                              due_on: 'date', seen_at: 'datetime(6)'))
        .to eq(%i[integer boolean text date datetime])
      expect(kinds('postgresql', rank: 'bigint', flag: 'boolean', label: 'character varying(9)',
                                 due_on: 'date', seen_at: 'timestamp(6) without time zone'))
        .to eq(%i[integer boolean text date datetime])
      expect(kinds('postgresql', label: 'text', seen_at: 'timestamp with time zone'))
        .to eq(%i[text datetime])
      %w[mysql2 trilogy].each do |adapter|
        expect(kinds(adapter, rank: 'int(10) unsigned', flag: 'tinyint(1)', label: 'varchar(255)',
                              due_on: 'date', seen_at: 'datetime(6)'))
          .to eq([:integer, :boolean, nil, :date, :datetime])
      end
      expect(kinds('sqlserver', rank: 'int', flag: 'bit', label: 'nvarchar(4000)', due_on: 'date',
                                seen_at: 'datetime2(6)'))
        .to eq([:integer, :boolean, nil, :date, :datetime])
    end

    it 'reads no kind for a type or an adapter it does not list' do
      expect(kinds('postgresql', label: 'character(6)', rank: 'integer[]')).to eq([nil, nil])
      expect(kinds('postgresql', label: 'citext')).to eq([nil])
      expect(kinds('sqlserver', seen_at: 'datetime', due_on: 'smalldatetime')).to eq([nil, nil])
      expect(kinds('oracle', rank: 'integer', label: 'varchar')).to eq([nil, nil])
      expect(kind('missing')).to be_nil
      expect(kind(nil)).to be_nil
    end

    it 'reads text only without a collation of its own' do
      expect(kinds('sqlite3', label: 'varchar', rank: 'integer', collation: 'NOCASE'))
        .to eq([nil, :integer])
    end

    it 'reads no kind where the attribute type casts another' do
      expect(kinds('sqlite3', amount: 'integer', rank: 'varchar')).to eq([nil, nil])
    end

    # Replaced columns would give these subclasses their types, so the columns
    # are the test database's own.
    it 'reads no kind where the attribute type serializes or recasts the column' do
      stub_const('ExactColumnSerialized', Class.new(ExactColumnItem))
      ExactColumnSerialized.serialize :label, coder: YAML
      expect(kind('label', ExactColumnSerialized)).to be_nil
      stub_const('ExactColumnRetyped', Class.new(ExactColumnItem))
      ExactColumnRetyped.attribute :rank, :string
      expect(kind('rank', ExactColumnRetyped)).to be_nil
    end

    it 'reads an enum by its subtype and a time-zone-aware time by the time it stores' do
      aware = Class.new(ExactColumnItem) { self.time_zone_aware_attributes = true }
      stub_const('ExactColumnAware', aware)
      expect([kind('status'), kind('seen_at', aware)]).to eq(%i[integer datetime])
    end
  end

  describe '.stored_type' do
    it 'unwraps an enum and a time zone converter, and leaves other types alone' do
      aware = Class.new(ExactColumnItem) { self.time_zone_aware_attributes = true }
      stub_const('ExactColumnAware', aware)
      stored = ->(model, name) { described_class.stored_type(model.type_for_attribute(name)) }
      expect(stored.call(ExactColumnItem, 'status')).to be_a(ActiveModel::Type::Integer)
      expect(stored.call(aware,
                         'seen_at').class).to eq(ExactColumnItem.type_for_attribute('seen_at').class)
      expect(stored.call(ExactColumnItem,
                         'label')).to equal(ExactColumnItem.type_for_attribute('label'))
    end
  end
end
