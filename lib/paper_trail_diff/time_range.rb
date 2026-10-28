# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Validates and applies a finite wall-clock range without loading model state.
  class TimeRange
    attr_reader :begin_time #: Time
    attr_reader :end_time #: Time

    #: (untyped) -> void
    def initialize(value)
      unless value.is_a?(Range) && value.begin && value.end
        raise InvalidTimeRangeError, '`within` must be a finite Range'
      end

      @begin_time = coerce_time(value.begin, boundary: :begin)
      @end_time = coerce_time(value.end, boundary: :end)
      @exclude_end = value.exclude_end?
      validate_order!
      freeze
    end

    #: () -> bool
    def exclude_end?
      @exclude_end
    end

    #: (untyped) -> bool
    def include?(value)
      timestamp = coerce_time(value, boundary: :timestamp)
      return false if timestamp < begin_time

      exclude_end? ? timestamp < end_time : timestamp <= end_time
    end

    #: (untyped) -> untyped
    def scope(relation)
      relation.where(created_at: query_range)
    end

    #: (untyped) -> untyped
    def trailing_scope(relation)
      column = relation.klass.arel_table[:created_at]
      relation.where(after_end(column))
    end

    # Each item's earliest version after the range, keyed by item id. One row
    # per item comes back from a NOT EXISTS rather than a window function, so
    # the query stays portable; a timestamp tie keeps the lower id.
    #: (untyped) -> Hash[String, untyped]
    def first_trailing_versions(relation)
      table = relation.klass.arel_table
      versions = trailing_scope(relation).where(no_earlier_trailing(table))
                                         .reorder(created_at: :asc, id: :asc).to_a
      first = {} #: Hash[String, untyped]
      versions.each { |version| first[version.item_id.to_s] ||= version }
      first
    end

    private

    # @rbs @exclude_end: bool

    #: (untyped) -> untyped
    def after_end(column)
      exclude_end? ? column.gteq(end_time) : column.gt(end_time)
    end

    #: (untyped) -> untyped
    def no_earlier_trailing(table)
      arel = Object.const_get(:Arel) #: untyped
      later = table.alias('paper_trail_diff_earlier_trailing')
      arel.const_get(:SelectManager).new
          .from(later)
          .project(arel.sql('1'))
          .where(earlier_trailing(table, later))
          .exists
          .not
    end

    # Mirrors the range's own end handling, so a version sitting exactly on an
    # inclusive end stays inside the range instead of masking the one after it.
    #: (untyped, untyped) -> untyped
    def earlier_trailing(table, later)
      same_item = later[:item_type].eq(table[:item_type])
                                   .and(later[:item_id].eq(table[:item_id]))
      same_item.and(after_end(later[:created_at])).and(later[:created_at].lt(table[:created_at]))
    end

    #: () -> Range[Time]
    def query_range
      exclude_end? ? (begin_time...end_time) : (begin_time..end_time)
    end

    #: (untyped, boundary: Symbol) -> Time
    def coerce_time(value, boundary:)
      unless value.respond_to?(:to_time)
        raise InvalidTimeRangeError, "`within` #{boundary} must be time-like"
      end

      time_value(value).getutc.freeze
    rescue ArgumentError, NoMethodError, TypeError => e
      raise InvalidTimeRangeError,
            "`within` #{boundary} must be time-like",
            cause: e
    end

    #: (untyped) -> Time
    def time_value(value)
      return value if value.is_a?(Time)

      utc = value.utc if value.respond_to?(:utc)
      utc.is_a?(Time) ? utc : value.to_time
    end

    #: () -> void
    def validate_order!
      return unless begin_time > end_time

      raise InvalidTimeRangeError, '`within` beginning must not follow its end'
    end
  end
end
