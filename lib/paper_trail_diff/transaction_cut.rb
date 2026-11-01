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
  module TransactionCut # rubocop:disable Metrics/ModuleLength
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

      # @rbs @time: Time
      # @rbs @strict: bool
    end

    # Roots, or transactions, per statement. SQL Server compiles every
    # statement afresh, since its ids are written into it, in time that grows
    # with their number; fewer statements than this cost more than they save.
    SLICE = 500
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
      (starts.keys | ends.keys).to_h do |id|
        [id, moved_window(model_class, id, range, starts[id], ends[id])]
      end
    end

    # A transaction holds its rows only while it runs, so in history as an
    # application saves it an edge moves by moments. A longer move means a
    # long transaction or rewritten times, which only the application can
    # judge, so each move is reported rather than logged or refused.
    #: (untyped, String, TimeRange, Time?, Time?) -> TimeRange
    def self.moved_window(model_class, id, range, start, finish)
      window = moved(range, start, finish)
      Instrumentation.notify(
        'moved_window',
        item_type: model_class.base_class.name, item_id: id,
        requested: range.to_range, window: window.to_range
      )
      window
    end
    private_class_method :moved_window

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
    # One statement per slice: a grouped pass over the roots' versions finds
    # both instants, and a join reads the versions saved at either. A lookup
    # per root, joined by UNION ALL, took SQL Server about a second per 200
    # roots to compile. Rows read without a model come back as the adapter
    # returns them, so the transaction is cast as the grouped query's keys are.
    #: (untyped, Array[untyped], Edge) -> Array[[String, untyped]]
    def self.nearest(versions, records, edge)
      transaction = versions.type_for_attribute('transaction_id')
      versions.connection.select_rows(nearest_sql(versions, records, edge)).map do |id, value|
        [id.to_s, transaction.cast(value)]
      end
    end
    private_class_method :nearest

    # The roots' versions saved in a transaction at either nearest instant.
    #: (untyped, Array[untyped], Edge) -> String
    def self.nearest_sql(versions, records, edge)
      own = versions.where(item_id: records)
      instants = nearest_instants(own, edge)
      own.joins(arel::Nodes::InnerJoin.new(instants, at_either(own.arel_table, instants)))
         .where.not(transaction_id: nil).select(:item_id, :transaction_id).to_sql
    end
    private_class_method :nearest_sql

    # Each root's latest instant before the edge and earliest after it, from
    # every version, saved in a transaction or not.
    #: (untyped, Edge) -> untyped
    def self.nearest_instants(own, edge)
      table = own.arel_table
      column = table[:created_at]
      before = side_instant(arel::Nodes::Max, edge.left(column), column).as('before_at')
      after = side_instant(arel::Nodes::Min, edge.right(column), column).as('after_at')
      own.group(:item_id).select(table[:item_id], before, after).arel.as('paper_trail_diff_nearest')
    end
    private_class_method :nearest_instants

    # The latest or earliest of the times on one side of the edge.
    #: (untyped, untyped, untyped) -> untyped
    def self.side_instant(aggregate, side, column)
      aggregate.new([arel::Nodes::Case.new.when(side).then(column)])
    end
    private_class_method :side_instant

    # The same root's versions saved at either of its instants.
    #: (untyped, untyped) -> untyped
    def self.at_either(table, instants)
      column = table[:created_at]
      at_either = column.eq(instants[:before_at]).or(column.eq(instants[:after_at]))
      arel::Nodes::On.new(table[:item_id].eq(instants[:item_id]).and(at_either))
    end
    private_class_method :at_either

    # Where each transaction that has versions on both sides of the edge began.
    #: (untyped, Array[untyped], Edge) -> Hash[untyped, Time]
    def self.crossing_starts(version_class, transactions, edge)
      earlier = edge.left(version_class.arel_table[:created_at])
      later = later_version(version_class.arel_table, edge)
      starts = {} #: Hash[untyped, Time]
      transactions.each_slice(SLICE).with_object(starts) do |slice, found|
        crossing = version_class.where(transaction_id: slice).where(earlier).where(later)
        found.merge!(crossing.group(:transaction_id).minimum(:created_at))
      end
    end
    private_class_method :crossing_starts

    # Another version of the same transaction on the edge's later side.
    #: (untyped, Edge) -> untyped
    def self.later_version(table, edge)
      other = other_versions(table)
      arel::SelectManager.new.from(other).project('1')
                         .where(other[:transaction_id].eq(table[:transaction_id])
                                  .and(edge.right(other[:created_at])))
                         .exists
    end
    private_class_method :later_version

    # The version table under a second name, for a subquery over it. Any name
    # serves, and SQLite even accepts an empty one other databases refuse, so
    # no spec can tell the mutations apart.
    # mutant:disable
    #: (untyped) -> untyped
    def self.other_versions(table)
      table.alias('paper_trail_diff_crossing_versions')
    end
    private_class_method :other_versions

    # Arel ships no signatures; see VersionQuery. Any spelling of the constant
    # finds the same module.
    # mutant:disable
    #: () -> untyped
    def self.arel
      Object.const_get(:Arel)
    end
    private_class_method :arel

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
