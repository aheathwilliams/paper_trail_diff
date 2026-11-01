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

  it "takes none on another adapter, or inside the caller's transaction" do
    allow(FilterArticle).to receive(:transaction)
    other = stub_const('OtherAdapterStandIn', adapter_class).new(false)

    expect([read(other), read(built_on_postgresql(open: true))]).to eq(%i[read read])
    expect(FilterArticle).not_to have_received(:transaction)
  end
end
