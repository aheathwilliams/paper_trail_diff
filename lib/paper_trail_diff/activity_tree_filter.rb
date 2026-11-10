# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Leaves out the events of records that were outside the root's tree.
  #
  # A record found in the tree at one time in a range brings every version it
  # saved in the range, including those it saved while it belonged elsewhere:
  # a comment edited on another article before it moved to this one, or after
  # it left a scope. Such a version changes nothing the root shows. As a
  # boundary it would open a step of its own, and inside a transaction, where
  # a change surfaces one event late, that step would take the credit for the
  # root's own change.
  #
  # PT-AT reads associations as they were before a transaction, so a record
  # is judged by two snapshots: the one at its transaction's first event, and
  # the one after its last, which is the next event's or what the range
  # closes on. A root version inside the transaction is the exception: it
  # reads the has_and_belongs_to_many members it records, including a record
  # the transaction created before it, so the snapshots at the transaction's
  # root events are read too. A tag created, attached and detached again
  # before the next root version is in the tree only there. A record in none
  # of these was outside the tree throughout.
  #
  # The root's own events are always kept. Every other event is judged,
  # whether or not its step is reported: one left in only bounds a reported
  # step, and which records' events a history holds depends on what else was
  # read with it, so an event of a record outside the tree would bound a step
  # in one read and not in another. A snapshot does not hold a through's join
  # rows, so their versions are judged when they are collected, by the row's
  # own state (PreparedActivityIndex#join_versions), and kept here.
  class ActivityTreeFilter
    # `closing` is the snapshot after the last event: the current record's,
    # or nil when nothing follows, as after the root's destruction.
    #: (Array[ActivityEvent], closing: RecordSnapshot?) -> void
    def initialize(events, closing:)
      @closing = closing
      @keys = transaction_keys(events)
      @starts, @ends = spans(@keys)
      @roots = root_positions(events)
      @types = {} #: Hash[String, Array[String?]]
    end

    # Yields each event of the sequence with its snapshot, and whether to keep
    # it, in order.
    #: (untyped) { (ActivityEvent, RecordSnapshot?, bool) -> void } -> void
    def call(sequence)
      pairs = sequence.to_enum.to_a #: Array[[ActivityEvent, RecordSnapshot?]]
      kept = kept(pairs)
      pairs.each_with_index { |(event, snapshot), index| yield event, snapshot, kept.fetch(index) }
    end

    private

    # @rbs @closing: RecordSnapshot?
    # @rbs @keys: Array[Array[untyped] | Integer]
    # @rbs @starts: Array[Integer]
    # @rbs @ends: Array[Integer]
    # @rbs @roots: Hash[Array[untyped] | Integer, Array[Integer]]
    # @rbs @types: Hash[String, Array[String?]]

    # Whether to keep each event. The snapshots are gone through once, in
    # order, each answering for the events it judges (see SnapshotMembers):
    # looking through a snapshot for each event made a replay's time grow
    # with its events times the records of the tree.
    #: (Array[[ActivityEvent, RecordSnapshot?]]) -> Array[bool]
    def kept(pairs)
      kept = pairs.map { |event, _snapshot| unjudged?(event) }
      members = SnapshotMembers.new
      judged(pairs, kept).zip(pairs.map(&:last) << @closing) do |indexes, snapshot|
        members.move_to(snapshot)
        indexes.each { |index| kept[index] ||= holds?(members, pairs.fetch(index).first) }
      end
      kept
    end

    # The root's own events are kept, and a through's join rows were judged
    # when they were collected.
    #: (ActivityEvent) -> bool
    def unjudged?(event) = event.root? || event.join?

    # The events each snapshot judges, by the snapshot's position, the one
    # after the last event being what the range closes on: an event is judged
    # by the snapshots at the first event and the root events of its
    # transaction, and by the one after its last event.
    #: (Array[[ActivityEvent, RecordSnapshot?]], Array[bool]) -> Array[Array[Integer]]
    def judged(pairs, kept)
      asked = Array.new(pairs.length + 1) { [] } #: Array[Array[Integer]]
      kept.each_with_index do |known, index|
        next if known

        positions = [@starts.fetch(index), *@roots.fetch(@keys.fetch(index), []),
                     @ends.fetch(index)]
        positions.uniq.each { |position| asked.fetch(position) << index }
      end
      asked
    end

    # Where each event's transaction starts, and the position just past its
    # last event. Two transactions can interleave, so a transaction's events
    # need not be adjacent.
    #: (Array[Array[untyped] | Integer]) -> [Array[Integer], Array[Integer]]
    def spans(keys)
      first = {} #: Hash[Array[untyped] | Integer, Integer]
      last = {} #: Hash[Array[untyped] | Integer, Integer]
      keys.each_with_index do |key, index|
        first[key] ||= index
        last[key] = index
      end
      [keys.map { |key| first.fetch(key) }, keys.map { |key| last.fetch(key) + 1 }]
    end

    # Where each transaction's root events are.
    #: (Array[ActivityEvent]) -> Hash[Array[untyped] | Integer, Array[Integer]]
    def root_positions(events)
      events.each_index.select { |index| events.fetch(index).root? }
            .group_by { |index| @keys.fetch(index) }
    end

    # A version saved outside a transaction is a transaction of its own,
    # keyed by its position.
    #: (Array[ActivityEvent]) -> Array[Array[untyped] | Integer]
    def transaction_keys(events)
      events.each_with_index.map do |event, index|
        ActivityTransactionGroups.transaction_key(event.version) || index
      end
    end

    #: (SnapshotMembers, ActivityEvent) -> bool
    def holds?(members, event)
      version = event.version
      branches = event.branches #: Array[String]
      members.holds?(branches, types(version.item_type), version.item_id)
    end

    # A version names its record's base class, and a snapshot the record's
    # own class, which may be any subclass of it.
    #: (String) -> Array[String?]
    def types(base_name)
      @types[base_name] ||= [base_name, *Object.const_get(base_name).descendants.map(&:name)]
    end
  end
end
