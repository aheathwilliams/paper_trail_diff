# frozen_string_literal: true

require_relative '../support/core_database'

RSpec.describe PaperTrailDiff::CandidateTable do
  let(:sql_server) { CoreArticle.connection.adapter_name == 'SQLServer' }
  let(:many) { Array.new(described_class::THRESHOLD + 1) { |index| (index + 1).to_s } }

  def selected(source)
    CoreArticle.connection.select_values(source.to_sql).map(&:to_s).sort_by(&:to_i)
  end

  it 'yields a list of at most THRESHOLD ids as it was given' do
    ids = many.first(described_class::THRESHOLD)

    expect(described_class.with(CoreArticle, ids) { |source| source }).to equal(ids)
  end

  it 'yields a longer list as it was given on any database but SQL Server' do
    skip 'SQL Server holds a long list in a table' if sql_server

    expect(described_class.with(CoreArticle, many) { |source| source }).to equal(many)
  end

  # A drop that fails, as on a connection that lost the table, must not hide
  # the error that ended the block.
  it 'keeps the error that ended the block when the drop fails' do
    connection = CoreArticle.connection
    allow(described_class).to receive(:table?).and_return(true)
    allow(described_class).to receive(:create)
    allow(described_class).to receive(:insert_values)
    allow(connection).to receive(:execute).and_call_original
    allow(connection).to receive(:execute).with(/DROP TABLE/)
                                          .and_raise(ActiveRecord::StatementInvalid, 'gone')

    expect { described_class.with(CoreArticle, many) { raise ArgumentError, 'timeout' } }
      .to raise_error(ArgumentError, 'timeout')
    expect(described_class.with(CoreArticle, many) { :done }).to eq(:done)
  end

  describe '.union' do
    let(:relations) do
      [CoreArticle.unscoped.where(id: [1, 2]).select(:id),
       CoreArticle.unscoped.where(id: [2, 3]).select(:id)]
    end

    it 'yields one relation as it was given' do
      expect(described_class.union(CoreArticle, relations.first(1)) { |sources| sources })
        .to eq(relations.first(1))
    end

    it 'yields several as they were given on any database but SQL Server' do
      skip 'SQL Server fills a table from them' if sql_server

      expect(described_class.union(CoreArticle, relations) { |sources| sources }).to eq(relations)
    end

    context 'with SQL Server' do
      before do
        skip 'needs SQL Server' unless sql_server
        CoreArticle.delete_all
        3.times { |index| CoreArticle.create!(title: "Article #{index}", internal_note: 'n') }
      end

      let(:ids) { CoreArticle.order(:id).pluck(:id) }
      let(:relations) do
        [CoreArticle.unscoped.where(id: ids.first(2)).select(:id),
         CoreArticle.unscoped.where(id: ids.last(2)).select(:id),
         CoreArticle.unscoped.where(id: ids.first).select(Arel.sql('NULL'))]
      end

      it 'yields one subquery that selects each id once, and no empty one' do
        selected = described_class.union(CoreArticle, relations) do |sources|
          expect(sources.length).to eq(1)
          selected(sources.first)
        end

        expect(selected).to eq(ids.map(&:to_s))
      end

      it 'drops the table when the block returns' do
        name = described_class.union(CoreArticle, relations) do |sources|
          sources.first.to_sql[/#paper_trail_diff_candidates_\h+/]
        end

        expect(CoreArticle.connection.select_value("SELECT OBJECT_ID('tempdb..#{name}')")).to be_nil
      end
    end
  end

  context 'with SQL Server' do
    before { skip 'needs SQL Server' unless sql_server }

    it 'drops quietly when the table is already gone' do
      result = described_class.with(CoreArticle, many) do |source|
        name = source.to_sql[/#paper_trail_diff_candidates_\h+/]
        CoreArticle.connection.execute("DROP TABLE #{name}")
        :done
      end

      expect(result).to eq(:done)
    end

    it 'yields a subquery that selects each id once' do
      ids = many + many.first(3)

      expect(described_class.with(CoreArticle, ids) { |source| selected(source) }).to eq(many)
    end

    it 'returns what the block returns and drops the table' do
      name = nil
      result = described_class.with(CoreArticle, many) do |source|
        name = source.to_sql[/#paper_trail_diff_candidates_\h+/]
        :done
      end

      expect(result).to eq(:done)
      expect(CoreArticle.connection.select_value("SELECT OBJECT_ID('tempdb..#{name}')")).to be_nil
    end

    it 'drops the table when the block raises' do
      name = nil
      expect do
        described_class.with(CoreArticle, many) do |source|
          name = source.to_sql[/#paper_trail_diff_candidates_\h+/]
          raise ArgumentError, 'stop'
        end
      end.to raise_error(ArgumentError, 'stop')

      expect(CoreArticle.connection.select_value("SELECT OBJECT_ID('tempdb..#{name}')")).to be_nil
    end

    it 'drops the table when filling it fails' do
      name = nil
      connection = CoreArticle.connection
      allow(connection).to receive(:execute).and_wrap_original do |original, sql, *rest|
        name ||= sql[/#paper_trail_diff_candidates_\h+/]
        raise ArgumentError, 'stop' if sql.start_with?('INSERT')

        original.call(sql, *rest)
      end

      expect { described_class.with(CoreArticle, many) { :unreached } }
        .to raise_error(ArgumentError, 'stop')
      expect(connection.select_value("SELECT OBJECT_ID('tempdb..#{name}')")).to be_nil
    end

    # The adapter reads an INSERT's table into the schema cache, which a
    # name used once would otherwise keep for the life of the pool.
    it 'leaves no entry for the table in the schema cache' do
      name = described_class.with(CoreArticle, many) do |source|
        source.to_sql[/#paper_trail_diff_candidates_\h+/]
      end

      expect(CoreArticle.connection.schema_cache.cached?(name)).to be(false)
    end

    # Active Record counts the table's statements as writes, as Rails'
    # automatic role switching prevents on a replica read.
    it 'yields the list while writes are prevented' do
      source = ActiveRecord::Base.while_preventing_writes do
        described_class.with(CoreArticle, many) { |ids| ids }
      end

      expect(source).to equal(many)
    end

    it 'gives the column a string key its type and collation' do
      column = Struct.new(:sql_type, :collation).new('nvarchar(255)', 'Latin1_General_CS_AS')
      allow(CoreArticle).to receive_messages(columns_hash: { 'id' => column },
                                             type_for_attribute: ActiveModel::Type::String.new)
      keys = many.map { |id| "key-#{id}" }

      expect(described_class.with(CoreArticle, keys) { |source| selected(source).sort })
        .to eq(keys.sort)
    end
  end
end
