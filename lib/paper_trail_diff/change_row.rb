# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # One change from an activity step, flat enough for a history table or an
  # export: a field that changed, or a record that appeared or disappeared,
  # with the event the step attributes it to.
  class ChangeRow
    attr_reader :change #: Symbol
    attr_reader :association_path #: Array[String]
    attr_reader :association_kind #: Symbol?
    # The record the row is about, or nil for the root itself.
    attr_reader :record #: RecordReference?
    # The field the row is about, or nil for a row about a whole record.
    attr_reader :attribute #: String?
    attr_reader :from #: untyped
    attr_reader :to #: untyped
    # The event that made the change: the version of the row's record that
    # recorded it, or a source of kind `:unversioned` for a change saved
    # without a version. A row the step's own events do not account for, such
    # as a record joining a collection through another record's change, names
    # the step's source boundary.
    attr_reader :source #: ActivityBoundary

    #: (change: Symbol, association_path: Array[String], association_kind: Symbol?, record: RecordReference?, attribute: String?, from: untyped, to: untyped, source: ActivityBoundary) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      change:, association_path:, association_kind:, record:, attribute:, from:, to:, source:
    )
      @change = change
      @association_path = association_path
      @association_kind = association_kind
      @record = record
      @attribute = attribute
      @from = from
      @to = to
      @source = source
      freeze
    end

    # Whether the change was saved without a version, such as with
    # `update_columns`, which PaperTrail never recorded. Only told apart with
    # `recorded_changes: true`.
    #: () -> bool
    def unversioned?
      source.unversioned?
    end

    # The source's identifying fields sit beside the change rather than nested,
    # so the hash is one row of a table as it stands.
    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        change: change, association_path: association_path, association_kind: association_kind,
        record: record&.to_h, attribute: attribute,
        from: Support.serialize(from), to: Support.serialize(to)
      }.merge(source_fields)
    end

    private

    #: () -> Hash[Symbol, untyped]
    def source_fields
      { version_id: source.version_id, event: source.event, whodunnit: source.whodunnit,
        recorded_at: source.recorded_at, transaction_id: source.transaction_id }
    end
  end

  # Flattens one step's diff into change rows, in the diff's walking order.
  #
  # A row is about one record. An edited field is `:changed`. A record that
  # appeared or disappeared is one `:added` or `:removed` row, followed by a
  # row for each of its fields and for each record it holds, so a table can
  # list a new comment's body without a second walker. That covers a record
  # joining or leaving a collection, a to-one target set, cleared or replaced
  # (the old target removed, then the new one added), and the root's own
  # creation or deletion.
  #
  # Two kinds of entry add nothing a row would show. One that only groups
  # others (an edited record, an association, a relationship) is left out,
  # because the rows under it name the same record. A nil field of an added
  # or removed record is left out too, because the record's own row already
  # says it appeared or disappeared; an empty string or false is a value.
  class ChangeRows
    RECORD_ENTRIES = %i[record_added record_removed record_included].freeze
    private_constant :RECORD_ENTRIES

    # `attribution` credits each row to the event that made its change, and
    # can split one in two (see ChangeAttribution); without it, every row is
    # credited to `source`.
    #: (Diff, source: ActivityBoundary, ?attribution: ChangeAttribution?) -> Array[ChangeRow]
    def self.call(diff, source:, attribution: nil)
      new(source, attribution).call(diff)
    end

    #: (ActivityBoundary, ChangeAttribution?) -> void
    def initialize(source, attribution)
      @source = source
      @attribution = attribution
    end

    #: (Diff) -> Array[ChangeRow]
    def call(diff)
      rows = [] #: Array[ChangeRow]
      attribution = @attribution
      diff.each_entry do |entry|
        row = row_for(entry)
        next unless row

        attribution ? rows.concat(attribution.call(row)) : rows << row
      end
      rows.freeze
    end

    private

    # @rbs @source: ActivityBoundary
    # @rbs @attribution: ChangeAttribution?

    #: (TraversalEntry) -> ChangeRow?
    def row_for(entry)
      return changed_row(entry) if entry.kind == :attribute_changed
      return presence_row(entry, nil) if RECORD_ENTRIES.include?(entry.kind)
      return unless entry.kind == :attribute_included && !entry.value.nil?

      presence_row(entry, entry.attribute)
    end

    #: (TraversalEntry) -> ChangeRow
    def changed_row(entry)
      value = entry.value #: ValueChange
      row(entry, :changed, entry.attribute, value.from, value.to)
    end

    # An added record's state is the after side and a removed one's the before
    # side, so a field's value goes on the side that has it.
    #: (TraversalEntry, String?) -> ChangeRow
    def presence_row(entry, attribute)
      value = (entry.value if attribute)
      return row(entry, :added, attribute, nil, value) if entry.state == :after

      row(entry, :removed, attribute, value, nil)
    end

    #: (TraversalEntry, Symbol, String?, untyped, untyped) -> ChangeRow
    def row(entry, change, attribute, from, to)
      ChangeRow.new(
        change: change, association_path: entry.association_path,
        association_kind: entry.association_kind, record: entry.record,
        attribute: attribute, from: from, to: to, source: @source
      )
    end
  end
end
