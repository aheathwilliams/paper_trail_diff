# frozen_string_literal: true
# rbs_inline: enabled

require 'securerandom'

module PaperTrailDiff
  # Holds a selection's candidate ids where every page of the selection can
  # join them, so that no page lists them.
  #
  # Each page of a plucked selection repeats its candidates, and SQL Server
  # compiles a statement with its values written in afresh: with 10,000 ids a
  # page took about 0.7 s, and with 20,000 a page could outlast the adapter's
  # default timeout. On SQL Server, a long list is written once into a
  # temporary table, and each page selects from it instead. Other databases
  # take the list as before: they parse it quickly, and the table would cost
  # them statements of their own.
  #
  # A temporary table belongs to the connection that made it, so the block runs
  # on one connection, and the table is dropped when it returns or raises.
  module CandidateTable
    # More ids than this go to a table: one statement's worth, as the gem
    # lists elsewhere, compiles quickly.
    THRESHOLD = Support::IDS_PER_STATEMENT #: Integer

    # SQL Server inserts at most 1,000 rows in one VALUES list.
    ROWS_PER_INSERT = 1_000

    # Yields the ids as they were given, or, on SQL Server with more than
    # THRESHOLD of them, a relation that selects them from a table, which a
    # condition such as `where(id: ...)` reads as a subquery.
    #: [T] (untyped, Array[String]) { (untyped) -> T } -> T
    def self.with(model, ids)
      return yield(ids) unless ids.length > THRESHOLD && sql_server?(model)

      model.connection_pool.with_connection do |connection|
        name = "#paper_trail_diff_candidates_#{SecureRandom.hex(8)}"
        create(connection, model, name, ids)
        begin
          yield model.unscoped.from("#{name} AS candidates").select('candidates.id')
        ensure
          connection.execute("DROP TABLE #{name}")
        end
      end
    end

    #: (untyped) -> bool
    def self.sql_server?(model)
      model.connection_pool.with_connection { |connection| connection.adapter_name == 'SQLServer' }
    end

    # The column takes the key's type and collation, so that comparing the two
    # neither converts every row nor meets tempdb's collation.
    #: (untyped, untyped, String, Array[String]) -> void
    def self.create(connection, model, name, ids)
      column = model.columns_hash.fetch(model.primary_key)
      connection.execute("CREATE TABLE #{name} (id #{column_type(column)} PRIMARY KEY)")
      type = model.type_for_attribute(model.primary_key)
      ids.uniq.each_slice(ROWS_PER_INSERT) do |slice|
        values = slice.map { |id| "(#{connection.quote(type.serialize(type.cast(id)))})" }
        connection.execute("INSERT INTO #{name} (id) VALUES #{values.join(', ')}")
      end
    end

    # The adapter writes an integer type with its size in bytes, as
    # `bigint(8)`, which SQL Server does not accept back.
    #: (untyped) -> String
    def self.column_type(column)
      type = column.sql_type.sub(/\A(tinyint|smallint|int|bigint)\(\d+\)\z/, '\\1')
      collation = column.collation if column.respond_to?(:collation)
      collation ? "#{type} COLLATE #{collation}" : type
    end

    private_class_method :sql_server?, :create, :column_type
  end
end
