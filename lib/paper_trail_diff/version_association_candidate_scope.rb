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
    def candidate_condition # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      connection = @version_class.connection
      outer = connection.quote_table_name(@version_class.table_name)
      later = connection.quote_table_name('paper_trail_diff_later_versions')
      start_at = connection.quote(@start_at)
      destroyed = connection.quote('destroy')
      activity = activity_condition(outer, start_at)
      compact_sql(<<~SQL)
        (
          #{activity}
          OR (
            #{column(outer, 'created_at')} < #{start_at}
            AND #{column(outer, 'event')} != #{destroyed}
            AND NOT EXISTS (
              SELECT 1
                FROM #{outer} #{later}
               WHERE #{column(later, 'item_type')} = #{column(outer, 'item_type')}
                 AND #{column(later, 'item_id')} = #{column(outer, 'item_id')}
                 AND #{column(later, 'created_at')} < #{start_at}
                 AND #{column(later, 'created_at')} > #{column(outer, 'created_at')}
            )
          )
        )
      SQL
    end

    #: (String, String) -> String
    def activity_condition(table, start_at)
      condition = "#{column(table, 'created_at')} >= #{start_at}"
      return condition unless @end_at

      end_at = @version_class.connection.quote(@end_at)
      "(#{condition} AND #{column(table, 'created_at')} <= #{end_at})"
    end

    #: (String, String) -> String
    def column(table, name)
      "#{table}.#{@version_class.connection.quote_column_name(name)}"
    end

    #: (String) -> String
    def compact_sql(sql)
      sql.gsub(/\s+/, ' ').strip
    end
  end
end
