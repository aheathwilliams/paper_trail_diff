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
    allow(described_class).to receive(:sql_server?).and_return(true)
    allow(described_class).to receive(:create)
    allow(connection).to receive(:execute).and_call_original
    allow(connection).to receive(:execute).with(/DROP TABLE/)
                                          .and_raise(ActiveRecord::StatementInvalid, 'gone')

    expect { described_class.with(CoreArticle, many) { raise ArgumentError, 'timeout' } }
      .to raise_error(ArgumentError, 'timeout')
    expect(described_class.with(CoreArticle, many) { :done }).to eq(:done)
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
