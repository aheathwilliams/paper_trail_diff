# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Applies the versions of one transaction to a snapshot, each to the record
  # it saved, as a version alone in its transaction is applied. A transaction's
  # changes appear together at the event after its last, so the snapshot there
  # is the one before it with every one of its versions applied; reading the
  # branches again instead costs every record in them.
  class ActivityTransactionApplier
    #: (ActivityEventSnapshotRefresher, ActivityRootSnapshotRefresher) -> void
    def initialize(event_refresher, root_refresher)
      @event_refresher = event_refresher
      @root_refresher = root_refresher
    end

    # nil when any event cannot be applied to the snapshot alone. Applying
    # only some would leave a record as no version left it.
    #: (untyped, untyped, RecordSnapshot, Array[ActivityEvent]) -> RecordSnapshot?
    def call(root_endpoint, context_endpoint, snapshot, events)
      events.reduce(snapshot) do |carried, event|
        handled, incremental = apply(root_endpoint, context_endpoint, carried, event)
        break unless handled && incremental

        incremental
      end
    end

    private

    # @rbs @event_refresher: ActivityEventSnapshotRefresher
    # @rbs @root_refresher: ActivityRootSnapshotRefresher

    # A record on several branches is applied on each.
    #: (untyped, untyped, RecordSnapshot, ActivityEvent) -> [bool, RecordSnapshot?]
    def apply(root_endpoint, context_endpoint, snapshot, event)
      return @root_refresher.call(root_endpoint, context_endpoint, snapshot, event) if event.root?

      branches = event.branches #: Array[String]
      branches.reduce([true, snapshot]) do |(_, carried), branch|
        handled, incremental = @event_refresher.call(root_endpoint, context_endpoint, carried,
                                                     [branch], event)
        break [false, nil] unless handled

        [true, incremental || carried]
      end
    end
  end
end
