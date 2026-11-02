# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::ReadSnapshot do
  # A connection that answers whether its caller has a transaction open.
  def adapter_class(parent = Object)
    Class.new(parent) do
      def initialize(open)
        super()
        @open = open
      end

      def transaction_open?
        @open
      end
    end
  end

  # A connection of an adapter built on PostgreSQL's, as PostGIS's is.
  def built_on_postgresql(open: false)
    base = stub_const('ActiveRecord::ConnectionAdapters::PostgreSQLAdapter', adapter_class)
    stub_const('PostGISAdapterStandIn', Class.new(base)).new(open)
  end

  def read(connection)
    allow(FilterArticle).to receive(:connection).and_return(connection)
    described_class.call([FilterArticle]) { :read }
  end

  it 'takes a snapshot on an adapter built on a snapshot adapter' do
    connection = built_on_postgresql
    allow(FilterArticle).to receive(:transaction).and_yield

    expect(read(connection)).to eq(:read)
    expect(FilterArticle).to have_received(:transaction).with(isolation: :repeatable_read)
  end

  # A SQL Server connection, and the snapshot_isolation_state its database
  # reports: 1 once ALLOW_SNAPSHOT_ISOLATION is ON.
  def sql_server(state, open: false)
    stub_const('ActiveRecord::ConnectionAdapters::SQLServerAdapter', adapter_class(Object))
      .new(open).tap do |connection|
        allow(connection).to receive(:select_value)
          .with(described_class::SQL_SERVER_SNAPSHOT_STATE, 'SCHEMA').and_return(state)
      end
  end

  it 'takes a SNAPSHOT read on SQL Server only when its database allows one' do
    allow(FilterArticle).to receive(:transaction).and_yield

    expect([read(sql_server(1)), read(sql_server(0)), read(sql_server(nil))])
      .to eq(%i[read read read])
    expect(FilterArticle).to have_received(:transaction).with(isolation: :snapshot).once
  end

  it 'reads nothing from SQL Server inside the caller\'s transaction' do
    connection = sql_server(1, open: true)
    allow(FilterArticle).to receive(:transaction)

    expect(read(connection)).to eq(:read)
    expect(connection).not_to have_received(:select_value)
    expect(FilterArticle).not_to have_received(:transaction)
  end

  it "takes none on another adapter, or inside the caller's transaction" do
    allow(FilterArticle).to receive(:transaction)
    other = stub_const('OtherAdapterStandIn', adapter_class).new(false)

    expect([read(other), read(built_on_postgresql(open: true))]).to eq(%i[read read])
    expect(FilterArticle).not_to have_received(:transaction)
  end

  # Run by the SQL Server CI jobs, one of which allows snapshot isolation.
  # Changing the setting here would wait for every open transaction. It skips
  # itself on other databases rather than being left out with `if:`, because
  # mutant runs an example it picks whatever its `if:` says.
  context 'with a SQL Server database' do
    # 5 is SNAPSHOT, 2 READ COMMITTED.
    def session_level
      FilterArticle.connection.select_value(
        'SELECT transaction_isolation_level FROM sys.dm_exec_sessions WHERE session_id = @@SPID'
      )
    end

    it 'reads at SNAPSHOT when the database allows it, and leaves the session as it was' do
      skip 'needs SQL Server' unless FilterArticle.connection.adapter_name == 'SQLServer'

      state = FilterArticle.connection.select_value(described_class::SQL_SERVER_SNAPSHOT_STATE)

      inside = described_class.call([FilterArticle]) { session_level }

      expect([inside, session_level]).to eq([state.to_i == 1 ? 5 : 2, 2])
    end
  end
end
