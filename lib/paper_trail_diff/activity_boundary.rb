# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Immutable metadata identifying one historical or current activity boundary.
  class ActivityBoundary
    attr_reader :kind #: Symbol
    attr_reader :version_id #: untyped
    attr_reader :item_type #: String
    attr_reader :item_id #: untyped
    attr_reader :recorded_at #: untyped
    attr_reader :event #: String?
    attr_reader :whodunnit #: untyped
    attr_reader :record #: RecordReference
    # The transaction the version was written in, when PaperTrail recorded one.
    # Several versions saved together share it, which is what lets a timeline
    # report one save as one step rather than as its parts.
    attr_reader :transaction_id #: untyped

    # @rbs @recorded_changes: untyped

    # Stands for recorded changes nobody asked to read, which differs from a
    # version that recorded nothing (nil).
    NOT_READ = Object.new.freeze
    NOT_READ_MESSAGE = 'recorded changes were not read; pass recorded_changes: true'
    private_constant :NOT_READ, :NOT_READ_MESSAGE

    class << self
      # `recorded:` names the attributes to leave out of the version's recorded
      # changes, or is nil when they were not asked for. Reading them decodes
      # `object_changes`, which a caller who does not want them should not pay.
      #: (untyped, ?recorded: Array[String]?) -> ActivityBoundary
      def from_version(version, recorded: nil)
        new(
          kind: :version,
          version_id: version.id,
          item_type: version.item_type,
          item_id: version.item_id,
          recorded_at: version.created_at,
          event: version.event,
          whodunnit: version.whodunnit,
          transaction_id: transaction_id(version),
          recorded_changes: recorded_changes(version, recorded)
        )
      end

      # The current record has no version, so it recorded nothing.
      #: (untyped, captured_at: untyped, ?recorded: Array[String]?) -> ActivityBoundary
      def current(record, captured_at:, recorded: nil)
        new(
          kind: :current,
          version_id: nil,
          item_type: record.class.base_class.name,
          item_id: record.id,
          recorded_at: captured_at,
          recorded_changes: recorded.nil? ? NOT_READ : nil
        )
      end

      # The state a `destroy` version leaves behind. A version records the state
      # before its own event, so the boundary built from a destroy version still
      # holds the record; this one is the absence that follows it.
      #: (untyped, ?recorded: Array[String]?) -> ActivityBoundary
      def destroyed(version, recorded: nil)
        new(
          kind: :destroyed,
          version_id: version.id,
          item_type: version.item_type,
          item_id: version.item_id,
          recorded_at: version.created_at,
          event: version.event,
          whodunnit: version.whodunnit,
          transaction_id: transaction_id(version),
          recorded_changes: recorded_changes(version, recorded)
        )
      end

      # A custom version class need not carry the column, and PaperTrail leaves
      # it nil outside a transaction. Both read as "no transaction here", which
      # groups with nothing.
      #: (untyped) -> untyped
      def transaction_id(version)
        version.transaction_id if version.respond_to?(:transaction_id)
      end

      private

      #: (untyped, Array[String]?) -> untyped
      def recorded_changes(version, ignore)
        return NOT_READ if ignore.nil?

        RecordedChanges.call(version, ignore: ignore)
      end
    end

    # `recorded_changes:` takes what `PaperTrailDiff.recorded_changes` returns
    # for the version; leave it out when they were not read.
    #: (kind: Symbol, version_id: untyped, item_type: untyped, item_id: untyped, recorded_at: untyped, ?event: untyped, ?whodunnit: untyped, ?transaction_id: untyped, ?recorded_changes: untyped) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      kind:,
      version_id:,
      item_type:,
      item_id:,
      recorded_at:,
      event: nil,
      whodunnit: nil,
      transaction_id: nil,
      recorded_changes: NOT_READ
    )
      @kind = kind
      @version_id = Support.immutable_copy(version_id)
      @item_type = Support.immutable_copy(item_type.to_s)
      @item_id = Support.immutable_copy(item_id)
      @recorded_at = Support.immutable_copy(recorded_at)
      @event = Support.immutable_copy(event&.to_s)
      @whodunnit = Support.immutable_copy(whodunnit)
      @transaction_id = Support.immutable_copy(transaction_id)
      @recorded_changes = recorded_changes
      @record = RecordReference.new(type: @item_type, id: @item_id)
      freeze
    end

    # What PaperTrail recorded with this boundary's version, as
    # `PaperTrailDiff.recorded_changes` returns it: nil when nothing was
    # recorded, and always nil for the current record, which has no version.
    # Raises unless the timeline was built with `recorded_changes: true`, so a
    # forgotten option cannot pass for a version that recorded nothing.
    #: () -> Hash[String, ValueChange]?
    def recorded_changes
      raise ConfigurationError, NOT_READ_MESSAGE unless recorded_changes?

      @recorded_changes
    end

    # Whether this boundary's recorded changes were read.
    #: () -> bool
    def recorded_changes?
      !NOT_READ.equal?(@recorded_changes)
    end

    #: () -> bool
    def version?
      kind == :version
    end

    #: () -> bool
    def current?
      kind == :current
    end

    #: () -> bool
    def destroyed?
      kind == :destroyed
    end

    #: (?metadata: bool) -> Hash[Symbol, untyped]
    def to_h(metadata: false)
      value = {
        kind: kind,
        version_id: version_id,
        item_type: item_type,
        item_id: item_id,
        recorded_at: recorded_at
      } #: Hash[Symbol, untyped]
      return value unless metadata

      value.merge!(event: event, whodunnit: whodunnit, transaction_id: transaction_id,
                   record: record.to_h)
      return value unless recorded_changes?

      value.merge(recorded_changes: @recorded_changes&.transform_values(&:to_h))
    end
  end

  # One adjacent transition in a descendant-aware activity timeline.
  class ActivityStep
    attr_reader :from_boundary #: ActivityBoundary
    attr_reader :to_boundary #: ActivityBoundary
    attr_reader :diff #: Diff
    # The reconstructed states this step was compared between, present only when
    # a caller asked for them. A diff carries what changed; a renderer that has
    # to name an unchanged field of a changed record needs the whole state, and
    # rebuilding it from the version table by hand is both slower and easy to
    # get wrong.
    attr_reader :from_snapshot #: RecordSnapshot?
    attr_reader :to_snapshot #: RecordSnapshot?
    # The events whose changes this step reports, in the order they happened.
    # That is `source_boundary` alone, unless the step is a transaction group,
    # which holds every event in it: an attribution that names only the first
    # would credit the rest of the save to whoever opened it.
    attr_reader :sources #: Array[ActivityBoundary]

    # Compares two reconstructed states and keeps them only when asked, which is
    # every caller's shape: the diff always comes from the pair, the pair itself
    # is retained on request.
    #: (from_boundary: ActivityBoundary, to_boundary: ActivityBoundary, from_snapshot: RecordSnapshot?, to_snapshot: RecordSnapshot?, retain: bool, ?sources: Array[ActivityBoundary]?) -> ActivityStep
    def self.between(from_boundary:, to_boundary:, from_snapshot:, to_snapshot:, retain:, sources: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      new(
        from_boundary: from_boundary,
        to_boundary: to_boundary,
        diff: Engine.compare(from_snapshot, to_snapshot),
        from_snapshot: (from_snapshot if retain),
        to_snapshot: (to_snapshot if retain),
        sources: sources
      )
    end

    #: (from_boundary: ActivityBoundary, to_boundary: ActivityBoundary, diff: Diff, ?from_snapshot: RecordSnapshot?, ?to_snapshot: RecordSnapshot?, ?sources: Array[ActivityBoundary]?) -> void
    def initialize(from_boundary:, to_boundary:, diff:, from_snapshot: nil, to_snapshot: nil, sources: nil) # rubocop:disable Metrics/ParameterLists, Layout/LineLength
      @from_boundary = from_boundary
      @to_boundary = to_boundary
      @diff = diff
      @from_snapshot = from_snapshot
      @to_snapshot = to_snapshot
      @sources = (sources || [from_boundary]).dup.freeze
      freeze
    end

    #: () -> bool
    def empty?
      diff.empty?
    end

    # The event whose change this step reports. For a transaction group, this
    # is the first event in the group, not necessarily its only actor or record.
    #: () -> ActivityBoundary
    def source_boundary = from_boundary

    # The diff as flat rows, each attributed to `source_boundary`.
    #: () -> Array[ChangeRow]
    def change_rows
      ChangeRows.call(diff, source: source_boundary)
    end

    # `metadata: true` also lists `sources`, since who made a change is
    # metadata as much as the source boundary's own author is.
    #: (?metadata: bool, ?snapshots: bool) -> Hash[Symbol, untyped]
    def to_h(metadata: false, snapshots: false)
      value = {
        from: from_boundary.to_h(metadata: metadata),
        to: to_boundary.to_h(metadata: metadata),
        diff: diff.to_h
      } #: Hash[Symbol, untyped]
      value[:sources] = sources.map { |source| source.to_h(metadata: true) } if metadata
      return value unless snapshots

      value.merge(from_snapshot: from_snapshot&.to_h, to_snapshot: to_snapshot&.to_h)
    end
  end
end
