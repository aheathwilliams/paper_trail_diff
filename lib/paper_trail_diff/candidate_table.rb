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
  # Active Record counts the table's statements as writes, so a read that
  # prevents writes, as a replica read through Rails' automatic role switching
  # does, takes the list instead.
  #
  # A temporary table belongs to the connection that made it, so the block runs
  # on one connection, and the table is dropped when it returns or raises,
  # even when filling it is what failed. A
  # reconnect inside the block, as Active Record makes to retry a read after
  # losing the connection, loses the table, and the read then fails naming it.
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
      return yield(ids) unless ids.length > THRESHOLD

      Support.with_connection(model) do |connection|
        next yield(ids) unless table?(connection)

        temporary(connection, model) do |name|
          insert_values(connection, model, name, ids)
          yield selection(model, name)
        end
      end
    end

    # Yields the subqueries as they were given, or, on SQL Server, one
    # relation that selects their ids from a table each fills in turn.
    #
    # A page that matches its rows against several subqueries joined by OR
    # has SQL Server plan them as one statement: with 1,600 orders and the
    # subqueries for their line items, it ran a line items' subquery again
    # for each order and took about 38 s, though each subquery alone took
    # under 0.2 s. Filled one statement at a time, each subquery runs once,
    # and every page then reads one keyed table. The ids stay in the
    # database, so a busy window costs no list in Ruby.
    #: [T] (untyped, Array[untyped]) { (Array[untyped]) -> T } -> T
    def self.union(model, relations)
      return yield(relations) unless relations.length > 1

      Support.with_connection(model) do |connection|
        next yield(relations) unless table?(connection)

        temporary(connection, model) do |name|
          relations.each { |relation| insert_selected(connection, name, relation) }
          yield [selection(model, name)]
        end
      end
    end

    #: (untyped) -> bool
    def self.table?(connection)
      connection.adapter_name == 'SQLServer' && !connection.preventing_writes?
    end

    # The table is dropped even when making or filling it is what failed.
    #: [T] (untyped, untyped) { (String) -> T } -> T
    def self.temporary(connection, model)
      name = "#paper_trail_diff_candidates_#{SecureRandom.hex(8)}"
      begin
        create(connection, model, name)
        yield name
      ensure
        drop(connection, name)
      end
    end

    # A condition such as `where(id: ...)` reads this as a subquery.
    #: (untyped, String) -> untyped
    def self.selection(model, name)
      model.unscoped.from("#{name} AS candidates").select('candidates.id')
    end

    # The column takes the key's type and collation, so that comparing the two
    # neither converts every row nor meets tempdb's collation.
    #: (untyped, untyped, String) -> void
    def self.create(connection, model, name)
      column = model.columns_hash.fetch(model.primary_key)
      connection.execute("CREATE TABLE #{name} (id #{column_type(column)} PRIMARY KEY)")
    end

    #: (untyped, untyped, String, Array[String]) -> void
    def self.insert_values(connection, model, name, ids)
      type = model.type_for_attribute(model.primary_key)
      ids.uniq.each_slice(ROWS_PER_INSERT) do |slice|
        values = slice.map { |id| "(#{connection.quote(type.serialize(type.cast(id)))})" }
        insert(connection, name, "SELECT id FROM (VALUES #{values.join(', ')}) AS listed (id)")
      end
    end

    #: (untyped, String, untyped) -> void
    def self.insert_selected(connection, name, relation)
      insert(connection, name, relation.to_sql)
    end

    # The source selects one column. An id already in the table, or none, is
    # left out, so the key holds each once.
    #
    # The statement starts with WITH rather than INSERT. The adapter reads the
    # table of every statement that starts with INSERT from the catalog, to
    # learn whether it has an identity column. For a temporary table that is a
    # query on tempdb's catalog, which another report's DROP TABLE can hold
    # locks on: two reports at the same time deadlocked there, and SQL Server
    # killed one of them.
    #: (untyped, String, String) -> void
    def self.insert(connection, name, source)
      connection.execute("WITH selected (id) AS (#{source}) " \
                         "INSERT INTO #{name} (id) SELECT id FROM selected " \
                         "WHERE id IS NOT NULL EXCEPT SELECT id FROM #{name}")
    end

    # The table can be gone already: a timeout that cost the connection,
    # which Active Record then reconnected, takes it along. A failed drop is
    # not raised, so that the error that ended the block is the one the caller
    # sees; a table left behind goes when its connection closes.
    #: (untyped, String) -> void
    def self.drop(connection, name)
      connection.execute("IF OBJECT_ID('tempdb..#{name}') IS NOT NULL DROP TABLE #{name}")
    rescue StandardError
      nil
    end

    # The adapter writes an integer type with its size in bytes, as
    # `bigint(8)`, which SQL Server does not accept back.
    #: (untyped) -> String
    def self.column_type(column)
      type = column.sql_type.sub(/\A(tinyint|smallint|int|bigint)\(\d+\)\z/, '\\1')
      collation = column.collation if column.respond_to?(:collation)
      collation ? "#{type} COLLATE #{collation}" : type
    end

    private_class_method :table?, :temporary, :selection, :create, :insert_values, :insert_selected,
                         :insert, :drop, :column_type
  end
end
