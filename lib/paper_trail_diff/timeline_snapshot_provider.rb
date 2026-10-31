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

    #: (untyped, Array[untyped]) -> PreparedTimelineSnapshots
    def prepare(record, versions)
      history = @store.prepare(record, versions)
      PreparedTimelineSnapshots.new(history, store: @store, live_snapshotter: @live_snapshotter)
    end

    # @rbs @store: HistoricalSnapshotStore
    # @rbs @live_snapshotter: untyped
  end

  # One root's timeline snapshots, read with the history prepared for it.
  # Adjacent steps share endpoints, so each immutable snapshot, including a
  # nil create state, is kept for this root only and released with it, and
  # batch memory does not retain every reconstructed graph.
  class PreparedTimelineSnapshots
    #: (PreparedHistory?, store: HistoricalSnapshotStore, live_snapshotter: untyped) -> void
    def initialize(history, store:, live_snapshotter:)
      @history = history
      @store = store
      @live_snapshotter = live_snapshotter
      @snapshots = {} #: Hash[Array[untyped], RecordSnapshot?]
    end

    # A window closing on current state ends at the live record rather than at a
    # version, which is the one endpoint no version history can reconstruct.
    #: (untyped) -> RecordSnapshot?
    def call(endpoint)
      key = [endpoint.class.name, endpoint.id]
      return @snapshots[key] if @snapshots.key?(key)

      @snapshots[key] = if Endpoint.record?(endpoint)
                          @live_snapshotter.call(endpoint)
                        else
                          @store.uncached(endpoint, endpoint, history: @history)
                        end
    end

    # @rbs @history: PreparedHistory?
    # @rbs @store: HistoricalSnapshotStore
    # @rbs @live_snapshotter: untyped
    # @rbs @snapshots: Hash[Array[untyped], RecordSnapshot?]
  end
end
