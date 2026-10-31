# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Moves each edge of a wall-clock window that falls inside one of a root's
  # transactions back to where that transaction began, so the transaction is
  # wholly in the later window.
  #
  # PT-AT reads a root's associations at the start of the transaction of the
  # root version it reifies. A window starting just after a child saved its
  # part of such a transaction therefore starts from the state before that
  # child's change, and one ending there ends at it too, so the change belonged
  # to no window and surfaced at the next transaction, under its author.
  #
  # Only the root's own versions on either side of an edge are consulted:
  # rows locked by an update keep two transactions of one root from
  # interleaving, so a transaction holding a root version and crossing the edge
  # holds the root's nearest version on one side of it. Each edge is moved from
  # where it was asked for, never from where another edge moved, so adjacent
  # windows move their shared edge alike.
  module TransactionCut
    # One edge of a window. A strict edge keeps versions recorded at its
    # instant on the left, as an inclusive end does. A plain class rather than
    # Data.define, which arrived in Ruby 3.2 while this gem supports 3.1.
    class Edge
      #: (Time, bool) -> void
      def initialize(time, strict)
        @time = time
        @strict = strict
        freeze
      end

      #: (untyped) -> untyped
      def left(column)
        @strict ? column.lteq(@time) : column.lt(@time)
      end

      #: (untyped) -> untyped
      def right(column)
        @strict ? column.gt(@time) : column.gteq(@time)
      end

      #: (untyped, later: bool) -> untyped
      def side(column, later:)
        later ? right(column) : left(column)
      end

      # @rbs @time: Time
      # @rbs @strict: bool
    end

    # Roots per statement: two lookups each stays under SQLite's limit of 500
    # terms in a compound SELECT.
    SLICE = 200
    private_constant :SLICE

    # The same as `windows` for a batch of roots, keyed by identity.
    #: (Array[untyped], TimeRange?) -> Hash[Array[String], TimeRange]
    def self.batch_windows(records, range)
      return {} unless range

      moved = {} #: Hash[Array[String], TimeRange]
      records.group_by(&:class).each_with_object(moved) do |(model_class, group), by_identity|
        identities = group.to_h { |record| [record.id.to_s, Endpoint.identity(record)] }
        windows(model_class, group, range).each do |id, window|
          by_identity[identities.fetch(id)] = window
        end
      end
    end

    # Where history for a batch must be read from: the earliest moved start.
    #: (TimeRange?, Hash[Array[String], TimeRange]) -> Time?
    def self.earliest_start(range, windows)
      return unless range

      [range.begin_time, *windows.each_value.map(&:begin_time)].min
    end

    # The windows that move, keyed by root id. A root missing from the result
    # keeps the window as asked.
    #: (untyped, Array[untyped], TimeRange) -> Hash[String, TimeRange]
    def self.windows(model_class, records, range)
      versions = transaction_versions(model_class)
      return {} unless versions

      starts = moved_edges(versions, records, Edge.new(range.begin_time, false))
      ends = moved_edges(versions, records, Edge.new(range.end_time, !range.exclude_end?))
      (starts.keys | ends.keys).to_h { |id| [id, moved(range, starts[id], ends[id])] }
    end

    #: (untyped) -> untyped
    def self.transaction_versions(model_class)
      return unless model_class.paper_trail.version_class.column_names.include?('transaction_id')

      VersionQuery.for_model(model_class)
    end
    private_class_method :transaction_versions

    # Each root's earliest start among its transactions that cross the edge.
    #: (untyped, Array[untyped], Edge) -> Hash[String, Time]
    def self.moved_edges(versions, records, edge)
      roots = nearest_roots(versions, records, edge)
      moved = {} #: Hash[String, Time]
      starts = crossing_starts(versions.klass, roots.keys, edge)
      starts.each_with_object(moved) do |(transaction, start), edges|
        roots.fetch(transaction).each { |id| edges[id] = [edges[id], start].compact.min }
      end
    end
    private_class_method :moved_edges

    # The roots whose versions next to the edge each transaction holds.
    #: (untyped, Array[untyped], Edge) -> Hash[untyped, Array[String]]
    def self.nearest_roots(versions, records, edge)
      records.each_slice(SLICE).flat_map { |slice| nearest(versions, slice, edge) }
             .group_by(&:last).transform_values { |pairs| pairs.map(&:first) }
    end
    private_class_method :nearest_roots

    # Each root's nearest versions on either side of an edge, as [id,
    # transaction] pairs; versions tied at the nearest instant are all kept.
    # One indexed lookup per root and side, where a single query over the
    # roots would read every version before the edge. The lookups are written
    # once with the root's id left open, as building a relation for each root
    # costs more than the query. Rows read as SQL text come back as the adapter
    # returns them, so the transaction is cast as the grouped query's keys are.
    #: (untyped, Array[untyped], Edge) -> Array[[String, untyped]]
    def self.nearest(versions, records, edge)
      lookup = nearest_lookups(versions, edge)
      item_id = versions.type_for_attribute('item_id')
      lookups = records.map do |record|
        versions.sanitize_sql_array([lookup, *Array.new(4, item_id.serialize(record.id))])
      end
      transaction = versions.type_for_attribute('transaction_id')
      versions.connection.select_rows(lookups.join(' UNION ALL ')).map do |id, value|
        [id.to_s, transaction.cast(value)]
      end
    end
    private_class_method :nearest

    # Both sides' lookups for a root whose id is each `?`.
    #: (untyped, Edge) -> String
    def self.nearest_lookups(versions, edge)
      own = versions.where("#{versions.quoted_table_name}.item_id = ?")
      "#{nearest_lookup(own, edge, false)} UNION ALL #{nearest_lookup(own, edge, true)}"
    end
    private_class_method :nearest_lookups

    #: (untyped, Edge, bool) -> String
    def self.nearest_lookup(own, edge, later)
      column = own.arel_table[:created_at]
      instant = own.where(edge.side(column, later: later))
                   .reorder(created_at: later ? :asc : :desc).limit(1).select(:created_at)
      own.where(column.eq(instant.arel)).where.not(transaction_id: nil)
         .select(:item_id, :transaction_id).to_sql
    end
    private_class_method :nearest_lookup

    # Where each transaction that has versions on both sides of the edge began.
    #: (untyped, Array[untyped], Edge) -> Hash[untyped, Time]
    def self.crossing_starts(version_class, transactions, edge)
      return {} if transactions.empty?

      column = version_class.arel_table[:created_at]
      scope = version_class.where(transaction_id: transactions)
      scope.where(edge.left(column))
           .where(transaction_id: scope.where(edge.right(column)).select(:transaction_id))
           .group(:transaction_id).minimum(:created_at)
    end
    private_class_method :crossing_starts

    #: (TimeRange, Time?, Time?) -> TimeRange
    def self.moved(range, start, finish)
      begin_time = start || range.begin_time
      return TimeRange.new(begin_time...[finish, begin_time].max) if finish
      return TimeRange.new(begin_time...range.end_time) if range.exclude_end?

      TimeRange.new(begin_time..range.end_time)
    end
    private_class_method :moved
  end
end
