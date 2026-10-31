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
  # closes on. A record in neither was outside the tree throughout.
  #
  # The root's own events are always kept, and so are the versions of a
  # through's join rows, which a snapshot does not hold, and an event whose
  # step is not reported, which only bounds one that is.
  class ActivityTreeFilter
    # `closing` is the snapshot after the last event: the current record's,
    # or nil when nothing follows, as after the root's destruction.
    #: (Array[ActivityEvent], reported: untyped, closing: RecordSnapshot?) -> void
    def initialize(events, reported:, closing:)
      @reported = reported
      @closing = closing
      @starts, @ends = spans(events)
      @types = {} #: Hash[String, Array[String?]]
    end

    # Yields each event of the sequence with its snapshot, and whether to keep
    # it, in order.
    #: (untyped) { (ActivityEvent, RecordSnapshot?, bool) -> void } -> void
    def call(sequence)
      pairs = sequence.to_enum.to_a #: Array[[ActivityEvent, RecordSnapshot?]]
      pairs.each_with_index do |(event, snapshot), index|
        yield event, snapshot, keep?(event, index, pairs)
      end
    end

    private

    # @rbs @reported: untyped
    # @rbs @closing: RecordSnapshot?
    # @rbs @starts: Array[Integer]
    # @rbs @ends: Array[Integer]
    # @rbs @types: Hash[String, Array[String?]]

    #: (ActivityEvent, Integer, Array[[ActivityEvent, RecordSnapshot?]]) -> bool
    def keep?(event, index, pairs)
      return true if event.root? || event.join? || !reported?(event)

      position = @ends.fetch(index)
      after = position < pairs.length ? pairs.fetch(position).last : @closing
      holds?(pairs.fetch(@starts.fetch(index)).last, event) || holds?(after, event)
    end

    #: (ActivityEvent) -> bool
    def reported?(event)
      !@reported || @reported.call(event)
    end

    # Where each event's transaction starts, and the position just past its
    # last event. Two transactions can interleave, so a transaction's events
    # need not be adjacent.
    #: (Array[ActivityEvent]) -> [Array[Integer], Array[Integer]]
    def spans(events)
      keys = transaction_keys(events)
      first = {} #: Hash[Array[untyped] | Integer, Integer]
      last = {} #: Hash[Array[untyped] | Integer, Integer]
      keys.each_with_index do |key, index|
        first[key] ||= index
        last[key] = index
      end
      [keys.map { |key| first.fetch(key) }, keys.map { |key| last.fetch(key) + 1 }]
    end

    # A version saved outside a transaction is a transaction of its own,
    # keyed by its position.
    #: (Array[ActivityEvent]) -> Array[Array[untyped] | Integer]
    def transaction_keys(events)
      events.each_with_index.map do |event, index|
        ActivityTransactionGroups.transaction_key(event.version) || index
      end
    end

    #: (RecordSnapshot?, ActivityEvent) -> bool
    def holds?(snapshot, event)
      return false unless snapshot

      version = event.version
      types = types(version.item_type)
      branches = event.branches #: Array[String]
      branches.any? { |name| contains?(snapshot.associations.fetch(name), types, version.item_id) }
    end

    #: (AssociationSnapshot, Array[String?], untyped) -> bool
    def contains?(association, types, id)
      types.any? { |type| association.position(type, id) } || association.records.any? do |record|
        record.associations.each_value.any? { |nested| contains?(nested, types, id) }
      end
    end

    # A version names its record's base class, and a snapshot the record's
    # own class, which may be any subclass of it.
    #: (String) -> Array[String?]
    def types(base_name)
      @types[base_name] ||= [base_name, *Object.const_get(base_name).descendants.map(&:name)]
    end
  end
end
