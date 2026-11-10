# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Prepares the snapshot store for TimelineBuilder, one root at a time.
  class TimelineSnapshotProvider
    #: (HistoricalSnapshotStore, live_snapshotter: untyped) -> void
    def initialize(store, live_snapshotter:)
      @store = store
      @live_snapshotter = live_snapshotter
    end

    # Each root version is reported where it was saved, and the records
    # around it read as they stood before every transaction that had not
    # ended yet (see TransactionEnds). So a window's history is read from
    # where the earliest transaction open at its start began, as a batch
    # reads it: one of them may have saved a record before the window. A
    # whole history begins at the root's first version instead.
    #: (untyped, Array[untyped], ?start_at: untyped) -> PreparedTimelineSnapshots
    def prepare(record, versions, start_at: nil)
      history = @store.prepare(record, versions, start_at: start_at)
      reach = history&.reach
      history = @store.prepare(record, versions, start_at: reach, reach: false) if reach
      ends = history&.transaction_ends(versions, floor: (versions.first unless start_at))
      PreparedTimelineSnapshots.new(history, ends, store: @store,
                                                   live_snapshotter: @live_snapshotter)
    end

    # @rbs @store: HistoricalSnapshotStore
    # @rbs @live_snapshotter: untyped
  end

  # One root's timeline snapshots, read with the history prepared for it.
  # Adjacent steps share endpoints, so each immutable snapshot, including a
  # nil create state, is kept for this root only and released with it, and
  # batch memory does not retain every reconstructed graph.
  class PreparedTimelineSnapshots
    #: (PreparedHistory?, TransactionEnds?, store: HistoricalSnapshotStore, live_snapshotter: untyped) -> void
    def initialize(history, ends, store:, live_snapshotter:)
      @history = history
      @ends = ends
      @store = store
      @live_snapshotter = live_snapshotter
      @snapshots = {} #: Hash[Array[untyped], RecordSnapshot?]
    end

    # A window closing on current state ends at the live record rather than at a
    # version, which is the one endpoint no version history can reconstruct.
    #: (untyped) -> RecordSnapshot?
    def call(endpoint)
      key = Support.row_key(endpoint)
      return @snapshots[key] if @snapshots.key?(key)

      @snapshots[key] = if Endpoint.record?(endpoint)
                          @live_snapshotter.call(endpoint)
                        else
                          at_version(endpoint)
                        end
    end

    private

    #: (untyped) -> RecordSnapshot?
    def at_version(version)
      history = @history
      ends = @ends
      return @store.uncached(version, version) unless history && ends

      snapshot = nil #: RecordSnapshot?
      history.reading(ends) { snapshot = @store.uncached(version, version, history: history) }
      snapshot
    end

    # @rbs @history: PreparedHistory?
    # @rbs @ends: TransactionEnds?
    # @rbs @store: HistoricalSnapshotStore
    # @rbs @live_snapshotter: untyped
    # @rbs @snapshots: Hash[Array[untyped], RecordSnapshot?]
  end
end
