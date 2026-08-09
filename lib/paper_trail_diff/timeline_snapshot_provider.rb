# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Gives TimelineBuilder one-argument access to a range-prepared snapshot store.
  class TimelineSnapshotProvider
    #: (HistoricalSnapshotStore) -> void
    def initialize(store)
      @store = store
    end

    #: (untyped, Array[untyped]) -> void
    def prepare(record, versions)
      @store.prepare(record, versions)
    end

    #: (untyped) -> RecordSnapshot?
    def call(version)
      @store.uncached(version, version)
    end

    # @rbs @store: HistoricalSnapshotStore
  end
end
