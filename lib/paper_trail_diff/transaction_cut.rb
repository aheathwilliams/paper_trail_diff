# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Answers where a range of versions really starts: where the transactions
  # of its roots' first versions began (`range_start`).
  #
  # PT-AT reads a root's associations at the start of the transaction of the
  # root version it reifies, so a range that starts at a version starts
  # before whatever that version's transaction saved earlier. A wall-clock
  # window does not move: it reports the transactions that end inside it
  # (see TransactionEnds and CrossingTransactions).
  module TransactionCut
    # An instant that a transaction can cross. A strict edge keeps versions recorded at its
    # instant on the left, as an inclusive end does. A plain class rather than
    # Data.define, which arrived in Ruby 3.2 while this gem supports 3.1.
    class Edge
      # A history's start at an instant, which keeps versions recorded at it
      # on the right.
      #: (Time) -> Edge
      def self.start_at(time) = new(time, false)

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

    # A range starting at a version starts before that version's transaction,
    # as PT-AT reads associations there. A version saved earlier in the same
    # transaction, such as the child update behind a `touch: true` parent
    # version, can be recorded before the start, so the start moves back to
    # where each root's first transaction in the range began. History loaded
    # from the start alone would read that child after its change.
    #: (Array[untyped], untyped) -> untyped
    def self.range_start(root_versions, start_at)
      versions = opening_versions(root_versions, start_at)
      return start_at if versions.empty?

      began = continued_starts(root_versions.first.class, versions, Edge.start_at(start_at))
      [start_at, *began.each_value].min
    end

    # Each root's first version at or after the start, where a transaction
    # saved it.
    #: (Array[untyped], untyped) -> Array[untyped]
    def self.opening_versions(root_versions, start_at)
      return [] unless start_at

      root_versions.reject { |version| version.created_at < start_at }
                   .sort_by { |version| Support.chronological_version_key(version) }
                   .uniq { |version| Endpoint.identity(version) }
                   .select { |version| VersionBoundary.transaction_id(version) }
    end
    private_class_method :opening_versions

    # Where the transactions of these versions, saved after the edge, began,
    # for those that saved a version before it. Of transactions that share a
    # number, only the one each version is in counts (see TransactionAnchors).
    #: (untyped, Array[untyped], Edge) -> Hash[untyped, Time]
    def self.continued_starts(version_class, versions, edge)
      began(version_class, versions, edge) do |slice, earlier|
        numbers = slice.map { |version| VersionBoundary.transaction_id(version) }
        TransactionAnchors.continued(earlier.where(transaction_id: numbers), version_class, edge,
                                     slice.map(&:id))
      end
    end

    # The earliest version before the edge of each transaction the block
    # picks from these versions, one statement per 500 of them.
    #: (untyped, Array[untyped], Edge) { (Array[untyped], untyped) -> untyped } -> Hash[untyped, Time]
    def self.began(version_class, items, edge)
      earlier = version_class.where(edge.left(version_class.arel_table[:created_at]))
      found = {} #: Hash[untyped, Time]
      items.each_slice(Support::IDS_PER_STATEMENT).with_object(found) do |slice, starts|
        starts.merge!(yield(slice, earlier).group(:transaction_id).minimum(:created_at))
      end
    end
    private_class_method :began
  end
end
