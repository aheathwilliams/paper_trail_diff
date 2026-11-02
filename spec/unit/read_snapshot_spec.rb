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

  def read(connection, values = [FilterArticle])
    allow(FilterArticle).to receive(:connection).and_return(connection)
    described_class.call(values) { :read }
  end

  # A versioned model on a connection of its own, whose transactions are
  # listed in `opened`. Its versions are its own unless another model holds
  # them.
  def model_on(connection, opened, name, versions: nil)
    Class.new do
      define_singleton_method(:connection) { connection }
      define_singleton_method(:paper_trail_options) { {} }
      define_singleton_method(:paper_trail) { Struct.new(:version_class).new(versions || self) }
      define_singleton_method(:transaction) do |isolation:, &block|
        opened << [name, isolation]
        block.call
      end
    end
  end

  it 'takes a snapshot on an adapter built on a snapshot adapter' do
    connection = built_on_postgresql
    allow(FilterArticle).to receive(:transaction).and_yield

    expect(read(connection)).to eq(:read)
    expect(FilterArticle).to have_received(:transaction).with(isolation: :repeatable_read)
  end

  it 'reads the model of a relation, a record or a version, and nothing of anything else' do
    article = FilterArticle.create!(title: 'Draft')
    connection = built_on_postgresql
    allow(FilterArticle).to receive(:transaction).and_yield
    unversioned = stub_const('UnversionedArticle',
                             Class.new(ActiveRecord::Base) { self.table_name = 'filter_articles' })

    [FilterArticle.where(title: 'Draft'), article, article.versions.first].each do |value|
      read(connection, [value])
    end
    expect(read(connection, ['a title', nil, String, unversioned, unversioned.new])).to eq(:read)
    expect(FilterArticle).to have_received(:transaction).exactly(3).times
  end

  # A relation runs some of its model's class methods in its own scope, which
  # would scope the whole read.
  it "opens a relation's snapshot on its model rather than on the relation" do
    relation = FilterArticle.where(title: 'Draft')
    allow(relation).to receive(:transaction).and_raise('opened on the relation')
    allow(FilterArticle).to receive(:transaction).and_yield

    expect(read(built_on_postgresql, [relation])).to eq(:read)
    expect(FilterArticle).to have_received(:transaction)
  end

  it "opens one snapshot for each connection, the first value's outermost" do
    opened = []
    first = model_on(built_on_postgresql, opened, :first)
    second = model_on(built_on_postgresql, opened, :second)
    shared = model_on(first.connection, opened, :shared)

    described_class.call([first, second, shared, first]) { opened << :read }

    expect(opened).to eq([%i[first repeatable_read], %i[second repeatable_read], :read])
  end

  it "takes a snapshot on the connection of a model's versions too" do
    opened = []
    versions = model_on(built_on_postgresql, opened, :versions)
    model = model_on(built_on_postgresql, opened, :model, versions: versions)

    described_class.call([model]) { opened << :read }

    expect(opened).to eq([%i[model repeatable_read], %i[versions repeatable_read], :read])
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

    steps = []
    allow(FilterArticle).to receive(:transaction) do |isolation:, &block|
      steps << isolation
      block.call
    end

    [1, '1', 0, nil].each { |state| steps << read(sql_server(state)) }

    expect(steps).to eq(%i[snapshot read snapshot read read read])
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
    unnamed = adapter_class.new(false)

    expect([read(other), read(unnamed), read(built_on_postgresql(open: true))])
      .to eq(%i[read read read])
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
