# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Gives TimelineBuilder one-argument access to a range-prepared snapshot store.
  class TimelineSnapshotProvider
    #: (HistoricalSnapshotStore, ?live_snapshotter: untyped) -> void
    def initialize(store, live_snapshotter: nil)
      @store = store
      @live_snapshotter = live_snapshotter
    end

    #: (untyped, Array[untyped]) -> void
    def prepare(record, versions)
      @store.prepare(record, versions)
    end

    # A window closing on current state ends at the live record rather than at a
    # version, which is the one endpoint no version history can reconstruct.
    #: (untyped) -> RecordSnapshot?
    def call(endpoint)
      return live_snapshot(endpoint) if Endpoint.record?(endpoint)

      @store.uncached(endpoint, endpoint)
    end

    private

    #: (untyped) -> RecordSnapshot?
    def live_snapshot(record)
      snapshotter = @live_snapshotter
      raise InvalidTimelineRangeError, 'live endpoints are unavailable here' unless snapshotter

      snapshotter.call(record)
    end

    # @rbs @store: HistoricalSnapshotStore
    # @rbs @live_snapshotter: untyped
  end
end
