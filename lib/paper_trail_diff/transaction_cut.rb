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
  # holds the root's nearest version on one side of it. One that saved the root
  # after the edge moves it. One that saved the root only before the edge moves
  # it only when it saved a record of a type on the requested paths after it,
  # which the root's history reads: without one, the root's change is in the
  # earlier window, where its version is, as selecting by a window's versions
  # finds it, and ScopedRootSelection selects the roots such a move brings into
  # a window. Each edge is moved from where it was asked for, never from where
  # another edge moved, so adjacent windows move their shared edge alike.
  module TransactionCut # rubocop:disable Metrics/ModuleLength
    # One edge of a window. A strict edge keeps versions recorded at its
    # instant on the left, as an inclusive end does. A plain class rather than
    # Data.define, which arrived in Ruby 3.2 while this gem supports 3.1.
    class Edge
      # A window's start, which keeps versions recorded at it on the right.
      #: (TimeRange) -> Edge
      def self.start_of(range) = new(range.begin_time, false)

      # A window's end, strict when the window includes it; an endless window
      # has none.
      #: (TimeRange) -> Edge?
      def self.end_of(range)
        finish = range.end_time
        new(finish, !range.exclude_end?) if finish
      end

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

    # The same as `windows` for a batch of roots, keyed by identity.
    #: (Array[untyped], TimeRange?, ?traversal: AssociationTraversal?) -> Hash[Array[String], TimeRange]
    def self.batch_windows(records, range, traversal: nil)
      return {} unless range

      moved = {} #: Hash[Array[String], TimeRange]
      records.group_by(&:class).each_with_object(moved) do |(model_class, group), by_identity|
        identities = group.to_h { |record| [record.id.to_s, Endpoint.identity(record)] }
        windows(model_class, group, range, traversal: traversal).each do |id, window|
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
    # keeps the window as asked. `traversal` names the requested paths.
    #: (untyped, Array[untyped], TimeRange, ?traversal: AssociationTraversal?) -> Hash[String, TimeRange]
    def self.windows(model_class, records, range, traversal: nil)
      versions = transaction_versions(model_class)
      return {} unless versions

      types = traversal&.path_types(model_class) || []
      starts = moved_edges(versions, records, Edge.start_of(range), types)
      finish = Edge.end_of(range)
      ends = finish ? moved_edges(versions, records, finish, types) : {} #: Hash[String, Time]
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

    # The model's versions in a window, and those saved before it in a
    # transaction that saved a record of one of `types` inside it, which
    # moves their root's window back to take them in: the versions that
    # select a root for the window. Without a window, every version does.
    #: (untyped, TimeRange?, Array[String]) -> untyped
    def self.window_versions(model_class, range, types)
      versions = VersionQuery.for_model(model_class)
      return versions unless range

      inside = range.scope(versions)
      version_class = model_class.paper_trail.version_class
      return inside if types.empty? || !transactional?(version_class)

      inside.or(crossing_versions(versions, version_class, range, types))
    end

    #: (untyped, untyped, TimeRange, Array[String]) -> untyped
    def self.crossing_versions(versions, version_class, range, types)
      transactions = range.scope(version_class.where(item_type: types)).select(:transaction_id)
      versions.where(version_class.arel_table[:created_at].lt(range.begin_time))
              .where(transaction_id: transactions)
    end
    private_class_method :crossing_versions

    #: (untyped) -> untyped
    def self.transaction_versions(model_class)
      VersionQuery.for_model(model_class) if transactional?(model_class.paper_trail.version_class)
    end
    private_class_method :transaction_versions

    #: (untyped) -> bool
    def self.transactional?(version_class)
      version_class.column_names.include?('transaction_id')
    end
    private_class_method :transactional?

    # Each root's earliest start among its transactions that cross the edge:
    # the one that saved its first version after the edge, which crosses when
    # it began before it, and the one that saved its last version before it,
    # which crosses when it saved a record of one of `types` after it.
    #: (untyped, Array[untyped], Edge, Array[String]) -> Hash[String, Time]
    def self.moved_edges(versions, records, edge, types)
      moved = {} #: Hash[String, Time]
      crossing(versions, records, edge, types).each_with_object(moved) do |(roots, starts), found|
        starts.each do |transaction, start|
          roots.fetch(transaction).each { |id| found[id] = [found[id], start].compact.min }
        end
      end
    end
    private_class_method :moved_edges

    # For each side of the edge, the roots its transactions hold next to the
    # edge, and where those that cross it began.
    #: (untyped, Array[untyped], Edge, Array[String]) -> Array[[Hash[untyped, Array[String]], Hash[untyped, Time]]]
    def self.crossing(versions, records, edge, types)
      later, earlier = nearest_roots(versions, records, edge)
      # @type var sides: Array[[Hash[untyped, Array[String]], Hash[untyped, Time]]]
      sides = [[later, crossing_starts(versions.klass, later.keys, edge)]]
      return sides if types.empty?

      sides << [earlier, crossing_starts(versions.klass, earlier.keys, edge, types)]
    end
    private_class_method :crossing

    # The roots whose versions next to the edge each transaction holds, those
    # after the edge and those before it.
    #: (untyped, Array[untyped], Edge) -> [Hash[untyped, Array[String]], Hash[untyped, Array[String]]]
    def self.nearest_roots(versions, records, edge)
      rows = records.each_slice(Support::IDS_PER_STATEMENT).flat_map do |slice|
        nearest(versions, slice, edge)
      end
      later, earlier = rows.partition(&:last)
      [by_transaction(later), by_transaction(earlier)]
    end
    private_class_method :nearest_roots

    # The roots of the rows, by the transaction each row names.
    #: (Array[[String, untyped, bool]]) -> Hash[untyped, Array[String]]
    def self.by_transaction(rows)
      rows.group_by { |row| row.fetch(1) }.transform_values { |group| group.map(&:first) }
    end
    private_class_method :by_transaction

    # Each root's nearest versions on either side of an edge, as [id,
    # transaction, after the edge] rows; versions tied at the nearest instant
    # are all kept. One statement per slice: a grouped pass over the roots'
    # versions finds both instants, and a join reads the versions saved at
    # either. A lookup per root, joined by UNION ALL, took SQL Server about a
    # second per 200 roots to compile. Rows read without a model come back as
    # the adapter returns them, so the transaction is cast as the grouped
    # query's keys are.
    #: (untyped, Array[untyped], Edge) -> Array[[String, untyped, bool]]
    def self.nearest(versions, records, edge)
      transaction = versions.type_for_attribute('transaction_id')
      rows = versions.connection.select_rows(nearest_sql(versions, records, edge))
      rows.map { |id, value, flag| [id.to_s, transaction.cast(value), after_edge?(flag)] }
    end
    private_class_method :nearest

    # The roots' versions saved in a transaction at either nearest instant,
    # each with whether it is the one after the edge.
    #: (untyped, Array[untyped], Edge) -> String
    def self.nearest_sql(versions, records, edge)
      own = versions.where(item_id: records)
      table = own.arel_table
      instants = nearest_instants(own, edge)
      own.joins(Support.arel::Nodes::InnerJoin.new(instants, at_either(table, instants)))
         .where.not(transaction_id: nil)
         .select(table[:item_id], table[:transaction_id], after_edge(table, instants)).to_sql
    end
    private_class_method :nearest_sql

    # 1 for a version saved at the instant after the edge, 0 for one before.
    # Only the 1 is read (see after_edge?), so another value or alias, or none,
    # answers the same.
    # mutant:disable
    #: (untyped, untyped) -> untyped
    def self.after_edge(table, instants)
      Support.arel::Nodes::Case.new.when(table[:created_at].eq(instants[:after_at]))
                               .then(1).else(0).as('after_edge')
    end
    private_class_method :after_edge

    # Whether after_edge flagged a row as saved after the edge. Adapters
    # return the flag as an Integer or a String, so any spelling that reads
    # only 1 as after answers the same.
    # mutant:disable
    #: (untyped) -> bool
    def self.after_edge?(flag)
      flag.to_i == 1
    end
    private_class_method :after_edge?

    # Each root's latest instant before the edge and earliest after it, from
    # every version, saved in a transaction or not.
    #: (untyped, Edge) -> untyped
    def self.nearest_instants(own, edge)
      table = own.arel_table
      column = table[:created_at]
      nodes = Support.arel::Nodes
      before = side_instant(nodes::Max, edge.left(column), column).as('before_at')
      after = side_instant(nodes::Min, edge.right(column), column).as('after_at')
      own.group(:item_id).select(table[:item_id], before, after).arel.as('paper_trail_diff_nearest')
    end
    private_class_method :nearest_instants

    # The latest or earliest of the times on one side of the edge.
    #: (untyped, untyped, untyped) -> untyped
    def self.side_instant(aggregate, side, column)
      aggregate.new([Support.arel::Nodes::Case.new.when(side).then(column)])
    end
    private_class_method :side_instant

    # The same root's versions saved at either of its instants.
    #: (untyped, untyped) -> untyped
    def self.at_either(table, instants)
      column = table[:created_at]
      at_either = column.eq(instants[:before_at]).or(column.eq(instants[:after_at]))
      Support.arel::Nodes::On.new(table[:item_id].eq(instants[:item_id]).and(at_either))
    end
    private_class_method :at_either

    # Where each transaction that saved a version before the edge began; with
    # `types`, only one that also saved a record of one of them after it.
    #: (untyped, Array[untyped], Edge, ?Array[String]?) -> Hash[untyped, Time]
    def self.crossing_starts(version_class, transactions, edge, types = nil)
      table = version_class.arel_table
      earlier = edge.left(table[:created_at])
      starts = {} #: Hash[untyped, Time]
      transactions.each_slice(Support::IDS_PER_STATEMENT).with_object(starts) do |slice, found|
        crossing = version_class.where(transaction_id: slice).where(earlier)
        crossing = crossing.where(later_version(table, edge, types)) if types
        found.merge!(crossing.group(:transaction_id).minimum(:created_at))
      end
    end
    private_class_method :crossing_starts

    # A version of the same transaction on the edge's later side, of a record
    # of one of `types`.
    #: (untyped, Edge, Array[String]) -> untyped
    def self.later_version(table, edge, types)
      VersionQuery.exists(table) do |other|
        other[:transaction_id].eq(table[:transaction_id])
                              .and(edge.right(other[:created_at]))
                              .and(other[:item_type].in(types))
      end
    end
    private_class_method :later_version

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
