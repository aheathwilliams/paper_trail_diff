# frozen_string_literal: true

require 'active_record'
if ENV.fetch('PAPER_TRAIL_DIFF_DATABASE_URL', '').start_with?('sqlserver:')
  require 'activerecord-sqlserver-adapter'
end

# Use only a disposable database: each suite recreates its fixture tables.
ActiveRecord::Base.establish_connection(
  ENV.fetch('PAPER_TRAIL_DIFF_DATABASE_URL') { { adapter: 'sqlite3', database: ':memory:' } }
)
ActiveRecord::Migration.verbose = false
ActiveRecord.yaml_column_permitted_classes = [Symbol, Time]
if ActiveRecord::Base.connection.adapter_name == 'SQLServer'
  # PaperTrail serializes SQL Server datetime2 values as adapter wrappers.
  ActiveRecord.yaml_column_permitted_classes += [
    ActiveRecord::ConnectionAdapters::SQLServer::Type::Data,
    ActiveRecord::ConnectionAdapters::SQLServer::Type::DateTime2
  ]
end
