# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Runs one read's statements inside one database snapshot. Without one, a row
  # that commits between two statements of the read can be seen by one of them
  # and missed by another: an activity read then found a comment whose versions
  # it had not read yet, and raised `KeyError`.
  #
  # PostgreSQL and MySQL (through mysql2 or trilogy), and adapters built on
  # them such as PostGIS, run the read at REPEATABLE READ, which gives every
  # statement of the transaction the same view. SQL Server runs it at SNAPSHOT
  # when the database allows that isolation level, which it does only after
  # `ALTER DATABASE ... SET ALLOW_SNAPSHOT_ISOLATION ON`; otherwise SNAPSHOT
  # raises, so it takes none. Other adapters get no snapshot; docs/reference.md
  # lists them under limitations.
  module ReadSnapshot
    # The adapters whose subclasses take a snapshot, by name, since an
    # application loads only the adapters it uses.
    SNAPSHOT_ADAPTERS = %w[
      ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
      ActiveRecord::ConnectionAdapters::AbstractMysqlAdapter
    ].freeze
    SQL_SERVER_ADAPTER = 'ActiveRecord::ConnectionAdapters::SQLServerAdapter'

    # 1 is ON. The setting can change while the application runs, so it is
    # read for each call; the catalog answers at once.
    SQL_SERVER_SNAPSHOT_STATE =
      'SELECT snapshot_isolation_state FROM sys.databases WHERE database_id = DB_ID()'

    # Yields once. Each connection the values read through gets a snapshot
    # transaction first, unless that connection already has a transaction open:
    # its isolation level belongs to the caller, and this gem cannot change it.
    # A value may be a model class, a relation, a record, or a version. Any
    # other value reads no table and is ignored.
    #: (Array[untyped]) { () -> untyped } -> untyped
    def self.call(values, &block)
      classes = connection_classes(values)
      classes.reverse_each.reduce(block) do |inner, klass|
        connection = klass.connection
        level = isolation(connection) unless connection.transaction_open?
        next inner unless level

        -> { klass.transaction(isolation: level) { inner.call } }
      end.call
    end

    # The isolation level that gives this connection's statements one view, or
    # nil when it has none.
    #: (untyped) -> Symbol?
    def self.isolation(connection)
      return :repeatable_read if adapter?(connection, SNAPSHOT_ADAPTERS)

      :snapshot if adapter?(connection, [SQL_SERVER_ADAPTER]) && sql_server_snapshot?(connection)
    end

    #: (untyped, Array[String]) -> bool
    def self.adapter?(connection, names)
      connection.class.ancestors.any? { |ancestor| names.include?(ancestor.name) }
    end

    # Named as a schema query, as Active Record names its own catalog reads.
    #: (untyped) -> bool
    def self.sql_server_snapshot?(connection)
      connection.select_value(SQL_SERVER_SNAPSHOT_STATE, 'SCHEMA').to_i == 1
    end

    # One class per connection: each read model and its version class, with the
    # repeats through a shared connection dropped. An associated model on
    # another database is not among them, so it is read outside the snapshot.
    #: (Array[untyped]) -> Array[untyped]
    def self.connection_classes(values)
      values.filter_map { |value| model_for(value) }
            .flat_map { |model| [model, model.paper_trail.version_class] }
            .uniq(&:connection)
    end

    # The versioned model a value reads from, or nil.
    #: (untyped) -> untyped
    def self.model_for(value)
      model = case value
              when Support.constant('ActiveRecord::Relation') then value.klass
              when Class then value
              else endpoint_model(value)
              end
      model if Support.versioned?(model)
    end

    # A version reads the model of its item; anything else its own class,
    # which is a versioned model only for a record.
    #: (untyped) -> untyped
    def self.endpoint_model(value)
      Endpoint.version?(value) ? Endpoint.model_class(value) : value.class
    end

    private_class_method :isolation, :adapter?, :sql_server_snapshot?, :model_for,
                         :endpoint_model
  end
end
