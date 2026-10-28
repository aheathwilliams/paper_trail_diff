# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Gives TimelineBuilder one-argument access to a range-prepared snapshot store.
  class TimelineSnapshotProvider
    #: (HistoricalSnapshotStore, live_snapshotter: untyped) -> void
    def initialize(store, live_snapshotter:)
      @store = store
      @live_snapshotter = live_snapshotter
      @snapshots = {} #: Hash[Array[untyped], RecordSnapshot?]
    end

    #: (untyped, Array[untyped]) -> void
    def prepare(record, versions)
      # Adjacent steps share endpoints. Keep their immutable snapshots for this
      # root only, including nil create states, and release them before the next
      # root so batch memory does not retain every reconstructed graph.
      @snapshots.clear
      @store.prepare(record, versions)
    end

    # A window closing on current state ends at the live record rather than at a
    # version, which is the one endpoint no version history can reconstruct.
    #: (untyped) -> RecordSnapshot?
    def call(endpoint)
      key = [endpoint.class.name, endpoint.id]
      return @snapshots[key] if @snapshots.key?(key)

      @snapshots[key] = if Endpoint.record?(endpoint)
                          live_snapshot(endpoint)
                        else
                          @store.uncached(endpoint, endpoint)
                        end
    end

    private

    #: (untyped) -> RecordSnapshot?
    def live_snapshot(record)
      @live_snapshotter.call(record)
    end

    # @rbs @store: HistoricalSnapshotStore
    # @rbs @live_snapshotter: untyped
    # @rbs @snapshots: Hash[Array[untyped], RecordSnapshot?]
  end
end
