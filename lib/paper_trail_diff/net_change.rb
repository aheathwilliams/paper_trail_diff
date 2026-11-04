# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # One record's net change over the change rows a caller kept: its state
  # before them, and that state with only the kept changes made. Built by
  # Analysis#net_changes (see NetChanges).
  class NetChange
    attr_reader :association_path #: Array[String]
    attr_reader :association_kind #: Symbol?
    # The record, or nil for the root itself, as on a change row.
    attr_reader :record #: RecordReference?
    # The record's fields when the step holding its first kept change began,
    # or nil where it was not there. The records it holds are left out: each
    # has an entry of its own.
    attr_reader :before #: RecordSnapshot?
    # `before` with only the kept changes made, or nil where they removed the
    # record.
    attr_reader :after #: RecordSnapshot?
    # `before` compared with `after`: the fields that differ, or the record's
    # appearance or removal.
    attr_reader :diff #: Diff
    # The events that made the kept changes, in order, each once.
    attr_reader :sources #: Array[ActivityBoundary]

    #: (association_path: Array[String], association_kind: Symbol?, record: RecordReference?, before: RecordSnapshot?, after: RecordSnapshot?, sources: Array[ActivityBoundary]) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      association_path:, association_kind:, record:, before:, after:, sources:
    )
      @association_path = association_path
      @association_kind = association_kind
      @record = record
      @before = before
      @after = after
      @diff = Engine.compare(before, after)
      @sources = sources.freeze
      freeze
    end

    #: () -> bool
    def root?
      association_path.empty?
    end

    # Whether the record was not there before its first kept change.
    #: () -> bool
    def added?
      before.nil?
    end

    # Whether the kept changes left the record gone.
    #: () -> bool
    def removed?
      after.nil?
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        association_path: association_path, association_kind: association_kind,
        record: record&.to_h, before: before&.to_h, after: after&.to_h, diff: diff.to_h,
        sources: sources.map { |source| source.to_h(metadata: true) }
      }
    end
  end

  # Folds an activity timeline's change rows into one NetChange for each
  # record a kept row is about, known by its association path and identity as
  # the row names it.
  #
  # A record's `before` is its state in the snapshot that the step of its
  # first kept row starts from. Each kept row then makes its change in time
  # order: a field takes the row's new value, and a row about the whole record
  # moves it in or out as the step's closing snapshot has it. A record that
  # appears takes that snapshot's fields, so a field no kept row sets keeps
  # the value it has there; the kept rows of its fields then replace any value
  # a dropped row left.
  class NetChanges
    # What one record's kept rows have made of it so far.
    class RecordFold
      # The rows that set a field; a removed record's rows leave them be.
      SETTING = %i[added changed].freeze
      private_constant :SETTING

      #: (ChangeRow, RecordSnapshot?) -> void
      def initialize(row, before)
        @row = row
        @before = before
        @read = before
        @present = !before.nil?
        @values = before ? before.attributes.dup : {} #: Hash[String, untyped]
        @sources = [] #: Array[ActivityBoundary]
      end

      # Makes one step's kept rows of the record. The block finds the record
      # in the step's closing snapshot, which only a row about the whole
      # record needs.
      #: (Array[ChangeRow]) { () -> RecordSnapshot? } -> void
      def apply(rows)
        whole = rows.reject(&:attribute)
        move(whole, yield) unless whole.empty?
        rows.each do |row|
          attribute = row.attribute
          @values[attribute] = row.to if attribute && SETTING.include?(row.change)
        end
        @sources.concat(rows.map(&:source))
      end

      #: () -> NetChange
      def net_change
        NetChange.new(
          association_path: @row.association_path, association_kind: @row.association_kind,
          record: @row.record, before: @before, after: after,
          sources: @sources.uniq(&:version_id)
        )
      end

      private

      # @rbs @row: ChangeRow
      # @rbs @before: RecordSnapshot?
      # The record as last read, which names it.
      # @rbs @read: RecordSnapshot?
      # @rbs @present: bool
      # @rbs @values: Hash[String, untyped]
      # @rbs @sources: Array[ActivityBoundary]

      # A record that appears, or moves between the records holding it, takes
      # its fields from where it ends up, which an added row's step holds.
      #: (Array[ChangeRow], RecordSnapshot?) -> void
      def move(whole, state)
        @present = !state.nil?
        return unless whole.any? { |row| row.change == :added }

        found = state #: RecordSnapshot
        @values = found.attributes.dup
        @read = found
      end

      # A record is there only once its own state was read, before its first
      # kept row or where it appeared.
      #: () -> RecordSnapshot?
      def after
        return unless @present

        read = @read #: RecordSnapshot
        RecordSnapshot.new(type: read.type, id: read.id, attributes: @values)
      end
    end

    # `keep` picks the rows to make; without it, every row is made.
    #: (Array[ActivityStep], (^(ChangeRow) -> boolish)?) -> Array[NetChange]
    def self.call(steps, keep)
      new(steps, keep).call
    end

    #: (Array[ActivityStep], (^(ChangeRow) -> boolish)?) -> void
    def initialize(steps, keep)
      @steps = steps
      @keep = keep
      @folds = {} #: Hash[Array[untyped], RecordFold]
      @holders = {} #: Hash[[RecordSnapshot, Array[String]], Array[RecordSnapshot]]
    end

    #: () -> Array[NetChange]
    def call
      check_snapshots!
      @steps.each do |step|
        rows = kept(step)
        next if rows.empty?

        @opening_root ||= flat(step.from_snapshot || step.to_snapshot)
        rows.group_by { |row| key(row) }.each { |key, record_rows| fold(key, step, record_rows) }
      end
      listed.freeze
    end

    private

    # @rbs @steps: Array[ActivityStep]
    # @rbs @keep: (^(ChangeRow) -> boolish)?
    # @rbs @folds: Hash[Array[untyped], RecordFold]
    # @rbs @holders: Hash[[RecordSnapshot, Array[String]], Array[RecordSnapshot]]
    # @rbs @opening_root: RecordSnapshot?

    # A step with a change has a state on at least one side, which it keeps
    # only when asked to.
    #: () -> void
    def check_snapshots!
      return if @steps.all? { |step| step.empty? || step.from_snapshot || step.to_snapshot }

      raise ConfigurationError, 'net_changes requires snapshots: true'
    end

    #: (ActivityStep) -> Array[ChangeRow]
    def kept(step)
      keep = @keep
      rows = step.change_rows
      keep ? rows.select(&keep) : rows
    end

    #: (ChangeRow) -> Array[untyped]
    def key(row)
      record = row.record
      [row.association_path, record&.type, record&.id]
    end

    #: (Array[untyped], ActivityStep, Array[ChangeRow]) -> void
    def fold(key, step, rows)
      row = rows.first #: ChangeRow
      record = @folds[key] ||= RecordFold.new(row, flat(locate(step.from_snapshot, row)))
      record.apply(rows) { locate(step.to_snapshot, row) }
    end

    # The root comes first whenever anything is listed, so a report has its
    # fields when only the records it holds changed; then each record in the
    # order of its first kept change. A record the kept changes left as it
    # was is left out.
    #: () -> Array[NetChange]
    def listed
      changes = @folds.values.map(&:net_change)
      changed = changes.reject { |change| change.diff.empty? }
      return changed if changed.empty?

      [changes.find(&:root?) || unchanged_root, *changed.reject(&:root?)]
    end

    # The root, without a kept change of its own, as the first kept change
    # found it.
    #: () -> NetChange
    def unchanged_root
      state = @opening_root
      NetChange.new(association_path: [], association_kind: nil, record: nil,
                    before: state, after: state, sources: [])
    end

    # The record a row is about in one of its step's snapshots, under any of
    # the records along its path; nil where it is not there.
    #: (RecordSnapshot?, ChangeRow) -> RecordSnapshot?
    def locate(snapshot, row)
      reference = row.record
      return snapshot unless snapshot && reference

      path = row.association_path
      holders(snapshot, path.take(path.length - 1)).each do |holder|
        association = holder.associations[path.fetch(-1)]
        next unless association

        position = association.position(reference.type, reference.id)
        return association.records.fetch(position) if position
      end
      nil
    end

    # The records reached through `parents` from the root, read once for each
    # snapshot.
    #: (RecordSnapshot, Array[String]) -> Array[RecordSnapshot]
    def holders(snapshot, parents)
      @holders[[snapshot, parents]] ||= reach(snapshot, parents)
    end

    #: (RecordSnapshot, Array[String]) -> Array[RecordSnapshot]
    def reach(snapshot, parents)
      parents.reduce([snapshot]) do |records, name|
        records.flat_map { |record| record.associations[name]&.records || [] }
      end
    end

    # The record's own fields, without the records it holds.
    #: (RecordSnapshot?) -> RecordSnapshot?
    def flat(snapshot)
      snapshot && RecordSnapshot.new(type: snapshot.type, id: snapshot.id,
                                     attributes: snapshot.attributes)
    end
  end
end
