# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The transactions open at each event of a root's timeline, other than the
  # event's own: those with an event before it and another after it. One
  # that began before the history did is open from the history's start.
  #
  # Two transactions that save in one tree at the same time interleave their
  # versions. A version of one reads the records the other saved by time, as
  # the other left them so far, yet those changes were not committed there,
  # and one the other undid before it ended, such as a comment it created and
  # deleted again, never was. So at each event a record an open transaction
  # saved reads as it stood before that transaction began, as a record the
  # event's own transaction saved does (see PreparedRecordIndex#reading),
  # until the event after the transaction's last. A transaction thus changes
  # no snapshot while it is open, and from one event to the next the
  # snapshots still differ only by what the earlier event's transaction
  # changed, once it ends, which is what ActivitySnapshotSequence refreshes.
  class InterleavedTransactions
    # The open transactions' ids, by the row key of each event's version, for
    # the events where any is open.
    #: (Array[ActivityEvent], opening: Array[Array[untyped]]) -> Hash[Array[untyped], Array[untyped]]
    def self.call(events, opening:)
      new(events, opening).call
    end

    #: (Array[ActivityEvent], Array[Array[untyped]]) -> void
    def initialize(events, opening)
      @events = events
      # A version saved outside a transaction is a transaction of its own,
      # keyed by its position, which ends where it begins.
      @keys = events.each_with_index.map do |event, index|
        ActivityTransactionGroups.transaction_key(event.version) || index
      end
      @last = {} #: Hash[Array[untyped] | Integer, Integer]
      @keys.each_with_index { |key, index| @last[key] = index }
      @open = opening.select { |key| @last.key?(key) }
    end

    #: () -> Hash[Array[untyped], Array[untyped]]
    def call
      found = {} #: Hash[Array[untyped], Array[untyped]]
      @keys.each_with_index do |key, index|
        others = advance(key, index)
        found[Support.row_key(@events.fetch(index).version)] = others unless others.empty?
      end
      found
    end

    private

    # @rbs @events: Array[ActivityEvent]
    # @rbs @keys: Array[Array[untyped] | Integer]
    # @rbs @last: Hash[Array[untyped] | Integer, Integer]
    # @rbs @open: Array[untyped]

    # The ids of the transactions open at an event, other than its own, as
    # the open ones move past it.
    #: (Array[untyped] | Integer, Integer) -> Array[untyped]
    def advance(key, index)
      @open.delete(key)
      others = @open.map(&:last)
      @open << key if @last.fetch(key) > index
      others
    end
  end
end
