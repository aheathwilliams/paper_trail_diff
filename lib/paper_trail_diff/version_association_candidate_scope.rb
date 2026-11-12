# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects association activity from a boundary forward plus the state at that boundary.
  class VersionAssociationCandidateScope
    #: (untyped, untyped, ?end_at: untyped) -> void
    def initialize(version_class, start_at, end_at: nil)
      @version_class = version_class
      @start_at = start_at
      @end_at = end_at
    end

    #: (untyped) -> untyped
    def call(relation)
      return relation unless @start_at

      relation.where(candidate_condition)
    end

    private

    # @rbs @version_class: untyped
    # @rbs @start_at: untyped
    # @rbs @end_at: untyped

    #: () -> String
    def candidate_condition
      Support.with_connection(@version_class) { |connection| condition_sql(connection) }
    end

    # A version saved before the start names the state there unless a later
    # one saved before the start replaced it. PT-AT stores the keys a version
    # saved, and a start inside a transaction reads each record as it stood
    # before the transaction, so a later version that a transaction across
    # the start saved before it replaced nothing yet. Without the version
    # before it, a record that this transaction moved away is not found, nor
    # is the transaction (see CrossingTransactions).
    #
    # The transaction crosses the start by a version of any record, not only
    # of this one: one that moved a comment away before the start and saved
    # only the comment's reply after it is found by the reply, which hangs
    # under the comment as it stood before. A transaction that went on to
    # save nothing in the tree brings a candidate the history loads and no
    # snapshot holds (see PreparedActivityIndex#eligible_version?).
    #: (untyped) -> String
    def condition_sql(connection) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      outer = connection.quote_table_name(@version_class.table_name)
      later = connection.quote_table_name('paper_trail_diff_later_versions')
      crossing = connection.quote_table_name('paper_trail_diff_crossing_versions')
      start_at = quote_time(connection, @start_at)
      columns = quoted_columns(connection, outer, later, crossing)
      compact_sql(<<~SQL)
        (
          #{activity_condition(columns, start_at, connection)}
          OR (
            #{columns.fetch(:outer_created_at)} < #{start_at}
            AND #{columns.fetch(:outer_event)} != #{connection.quote('destroy')}
            AND NOT EXISTS (
              SELECT 1
                FROM #{outer} #{later}
               WHERE #{columns.fetch(:later_item_type)} = #{columns.fetch(:outer_item_type)}
                 AND #{columns.fetch(:later_item_id)} = #{columns.fetch(:outer_item_id)}
                 AND #{columns.fetch(:later_created_at)} < #{start_at}
                 AND #{columns.fetch(:later_created_at)} > #{columns.fetch(:outer_created_at)}
                 AND NOT EXISTS (
                   SELECT 1
                     FROM #{outer} #{crossing}
                    WHERE #{columns.fetch(:crossing_transaction_id)} = #{columns.fetch(:later_transaction_id)}
                      AND #{columns.fetch(:crossing_created_at)} >= #{start_at}
                 )
            )
          )
        )
      SQL
    end

    #: (untyped, String, String, String) -> Hash[Symbol, String]
    def quoted_columns(connection, outer, later, crossing)
      {
        outer_created_at: column(connection, outer, 'created_at'),
        outer_event: column(connection, outer, 'event'),
        outer_item_type: column(connection, outer, 'item_type'),
        outer_item_id: column(connection, outer, 'item_id'),
        later_created_at: column(connection, later, 'created_at'),
        later_item_type: column(connection, later, 'item_type'),
        later_item_id: column(connection, later, 'item_id'),
        later_transaction_id: column(connection, later, 'transaction_id'),
        crossing_created_at: column(connection, crossing, 'created_at'),
        crossing_transaction_id: column(connection, crossing, 'transaction_id')
      }
    end

    #: (Hash[Symbol, String], String, untyped) -> String
    def activity_condition(columns, start_at, connection)
      created_at = columns.fetch(:outer_created_at)
      condition = "#{created_at} >= #{start_at}"
      return condition unless @end_at

      "(#{condition} AND #{created_at} <= #{quote_time(connection, @end_at)})"
    end

    # A time quoted on its own takes the adapter's default precision, which on
    # SQL Server is `datetime` and rounds to 1/300 second. Serializing through
    # the column's type quotes it as a bound value would be, at the precision
    # `created_at` is stored with.
    #: (untyped, untyped) -> String
    def quote_time(connection, time)
      type = @version_class.type_for_attribute('created_at')
      connection.quote(type.serialize(type.cast(time)))
    end

    #: (untyped, String, String) -> String
    def column(connection, table, name)
      "#{table}.#{connection.quote_column_name(name)}"
    end

    #: (String) -> String
    def compact_sql(sql)
      sql.split.join(' ')
    end
  end
end
