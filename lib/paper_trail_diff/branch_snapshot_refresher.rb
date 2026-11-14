# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reconstructs selected root branches and merges them into a prior immutable snapshot.
  class BranchSnapshotRefresher
    #: (ignore_policy: IgnorePolicy, traversal: AssociationTraversal, pool: SnapshotPool, normalizer: SnapshotNormalizer, full_snapshotter: untyped, partial_snapshotter: untyped, association_reader: untyped, record_transition: untyped, ?prepared_record_after: untyped, ?root_state: untyped) -> void
    def initialize( # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
      ignore_policy:,
      traversal:,
      pool:,
      normalizer:,
      full_snapshotter:,
      partial_snapshotter:,
      association_reader:,
      record_transition:,
      prepared_record_after: nil,
      root_state: nil
    )
      @tree = traversal.tree
      @ignore_policy = ignore_policy
      @traversal = traversal
      @pool = pool
      @full_snapshotter = full_snapshotter
      @partial_snapshotter = partial_snapshotter
      @components = {} #: Hash[Array[String], [AssociationTree, SnapshotNormalizer]]
      @event_refresher = ActivityEventSnapshotRefresher.new(
        traversal: traversal, pool: pool,
        components: method(:components),
        association_reader: association_reader,
        record_transition: record_transition,
        prepared_record_after: prepared_record_after
      )
      @root_refresher = ActivityRootSnapshotRefresher.new(
        traversal: traversal, normalizer: normalizer,
        record_after: @event_refresher.method(:record_after),
        changeset: @event_refresher.method(:deserialized_changeset),
        partial_snapshotter: method(:partial_snapshot),
        record_transition: record_transition,
        root_state: root_state
      )
      @applier = ActivityTransactionApplier.new(@event_refresher, @root_refresher)
    end

    # Without associations there is no prepared history, so nothing but the
    # version's own record could say what it left, and that misses a change
    # saved after it without a version. A full snapshot reads the next
    # recorded state instead, and with no branches to carry it costs no more.
    #: (untyped, untyped, RecordSnapshot?, event: ActivityEvent) -> RecordSnapshot?
    def advance_root(root_endpoint, context_endpoint, previous_snapshot, event:)
      return full_snapshot(root_endpoint, context_endpoint) if @tree.empty?

      handled, incremental = @root_refresher.call(
        root_endpoint,
        context_endpoint,
        previous_snapshot,
        event
      )
      return incremental if handled

      full_snapshot(root_endpoint, context_endpoint)
    end

    #: (untyped, untyped, RecordSnapshot?, Array[String], ?event: ActivityEvent?, ?isolated: bool) -> RecordSnapshot?
    def call( # rubocop:disable Metrics/ParameterLists
      root_endpoint,
      context_endpoint,
      previous_snapshot,
      branches,
      event: nil,
      isolated: false
    )
      return full_snapshot(root_endpoint, context_endpoint) unless previous_snapshot

      if isolated && event && branches.length > 1
        return refresh_independent_branches(root_endpoint, context_endpoint, previous_snapshot,
                                            branches, event)
      end

      if isolated
        handled, incremental = @event_refresher.call(root_endpoint, context_endpoint,
                                                     previous_snapshot, branches, event)
        return incremental if handled
      end
      refreshed(root_endpoint, context_endpoint, previous_snapshot, branches)
    end

    # The snapshot after a transaction that saved several records: each of
    # its events applied in turn to the record it saved, as an event alone in
    # its transaction is. Where one cannot be applied that way, the
    # transaction's branches are read again instead, or the whole snapshot
    # when the root is among the records it saved (`branches` is nil).
    #: (untyped, untyped, RecordSnapshot, Array[String]?, Array[ActivityEvent]) -> RecordSnapshot?
    def apply_transaction(root_endpoint, context_endpoint, previous_snapshot, branches, events)
      snapshot = @applier.call(root_endpoint, context_endpoint, previous_snapshot, events)
      return snapshot if snapshot
      return full_snapshot(root_endpoint, context_endpoint) unless branches

      refreshed(root_endpoint, context_endpoint, previous_snapshot, branches)
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @ignore_policy: IgnorePolicy
    # @rbs @traversal: AssociationTraversal
    # @rbs @pool: SnapshotPool
    # @rbs @full_snapshotter: untyped
    # @rbs @partial_snapshotter: untyped
    # @rbs @components: Hash[Array[String], [AssociationTree, SnapshotNormalizer]]
    # @rbs @event_refresher: ActivityEventSnapshotRefresher
    # @rbs @root_refresher: ActivityRootSnapshotRefresher
    # @rbs @applier: ActivityTransactionApplier

    #: (untyped, untyped, RecordSnapshot, Array[String], ActivityEvent) -> RecordSnapshot?
    def refresh_independent_branches( # rubocop:disable Metrics/MethodLength
      root_endpoint,
      context_endpoint,
      previous_snapshot,
      branches,
      event
    )
      snapshot = previous_snapshot
      remaining = [] #: Array[String]
      branches.each do |branch|
        handled, incremental = @event_refresher.call(
          root_endpoint,
          context_endpoint,
          snapshot,
          [branch],
          event
        )
        if handled
          snapshot = incremental || snapshot
        else
          remaining << branch
        end
      end
      return snapshot if remaining.empty?

      refreshed(root_endpoint, context_endpoint, snapshot, remaining)
    end

    # The snapshot with these branches read again from history, or a full
    # snapshot when they cannot be read alone.
    #: (untyped, untyped, RecordSnapshot, Array[String]) -> RecordSnapshot?
    def refreshed(root_endpoint, context_endpoint, snapshot, branches)
      partial = partial_snapshot(root_endpoint, context_endpoint, branches)
      partial ? merge(snapshot, partial) : full_snapshot(root_endpoint, context_endpoint)
    end

    #: (untyped, untyped, Array[String]) -> RecordSnapshot?
    def partial_snapshot(root_endpoint, context_endpoint, branches)
      tree, normalizer = components(branches)
      @partial_snapshotter.call(
        root_endpoint,
        context_endpoint,
        tree: tree,
        normalizer: normalizer
      )
    end

    #: (Array[String]) -> [AssociationTree, SnapshotNormalizer]
    def components(branches)
      return @components[branches] if @components.key?(branches)

      key = branches.sort.freeze
      @components[key] ||= build_components(key)
    end

    #: (Array[String]) -> [AssociationTree, SnapshotNormalizer]
    def build_components(branches)
      tree = @tree.select(branches)
      normalizer = SnapshotNormalizer.new(
        tree: tree,
        ignore_policy: @ignore_policy,
        traversal: @traversal,
        pool: @pool
      )
      [tree, normalizer]
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def full_snapshot(root_endpoint, context_endpoint)
      @full_snapshotter.call(root_endpoint, context_endpoint)
    end

    #: (RecordSnapshot, RecordSnapshot) -> RecordSnapshot
    def merge(previous, partial)
      RecordSnapshot.new(
        type: previous.type,
        id: previous.id,
        attributes: previous.attributes,
        associations: previous.associations.merge(partial.associations)
      )
    end
  end
end
