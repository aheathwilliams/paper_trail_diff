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

    # Only quoting helpers are needed, so the connection is borrowed for the
    # duration of building the condition rather than checked out permanently,
    # which Active Record 7.2 and newer can deprecate. Active Record 7.1 has no
    # `with_connection` and reaches the same connection through the accessor.
    #: () { (untyped) -> String } -> String
    def with_connection(&block)
      return @version_class.with_connection(&block) if @version_class.respond_to?(:with_connection)

      block.call(@version_class.connection)
    end

    #: () -> String
    def candidate_condition
      with_connection { |connection| condition_sql(connection) }
    end

    #: (untyped) -> String
    def condition_sql(connection) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      outer = connection.quote_table_name(@version_class.table_name)
      later = connection.quote_table_name('paper_trail_diff_later_versions')
      start_at = connection.quote(@start_at)
      columns = quoted_columns(connection, outer, later)
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
            )
          )
        )
      SQL
    end

    #: (untyped, String, String) -> Hash[Symbol, String]
    def quoted_columns(connection, outer, later)
      {
        outer_created_at: column(connection, outer, 'created_at'),
        outer_event: column(connection, outer, 'event'),
        outer_item_type: column(connection, outer, 'item_type'),
        outer_item_id: column(connection, outer, 'item_id'),
        later_created_at: column(connection, later, 'created_at'),
        later_item_type: column(connection, later, 'item_type'),
        later_item_id: column(connection, later, 'item_id')
      }
    end

    #: (Hash[Symbol, String], String, untyped) -> String
    def activity_condition(columns, start_at, connection)
      created_at = columns.fetch(:outer_created_at)
      condition = "#{created_at} >= #{start_at}"
      return condition unless @end_at

      "(#{condition} AND #{created_at} <= #{connection.quote(@end_at)})"
    end

    #: (untyped, String, String) -> String
    def column(connection, table, name)
      "#{table}.#{connection.quote_column_name(name)}"
    end

    #: (String) -> String
    def compact_sql(sql)
      sql.gsub(/\s+/, ' ').strip
    end
  end
end
