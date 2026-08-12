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

    class << self
      #: (untyped) -> ActivityBoundary
      def from_version(version)
        new(
          kind: :version,
          version_id: version.id,
          item_type: version.item_type,
          item_id: version.item_id,
          recorded_at: version.created_at,
          event: version.event,
          whodunnit: version.whodunnit
        )
      end

      #: (untyped, captured_at: untyped) -> ActivityBoundary
      def current(record, captured_at:)
        new(
          kind: :current,
          version_id: nil,
          item_type: record.class.base_class.name,
          item_id: record.id,
          recorded_at: captured_at
        )
      end

      # The state a `destroy` version leaves behind. A version records the state
      # before its own event, so the boundary built from a destroy version still
      # holds the record; this one is the absence that follows it.
      #: (untyped) -> ActivityBoundary
      def destroyed(version)
        new(
          kind: :destroyed,
          version_id: version.id,
          item_type: version.item_type,
          item_id: version.item_id,
          recorded_at: version.created_at,
          event: version.event,
          whodunnit: version.whodunnit
        )
      end
    end

    #: (kind: Symbol, version_id: untyped, item_type: untyped, item_id: untyped, recorded_at: untyped, ?event: untyped, ?whodunnit: untyped) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      kind:,
      version_id:,
      item_type:,
      item_id:,
      recorded_at:,
      event: nil,
      whodunnit: nil
    )
      @kind = kind
      @version_id = Support.immutable_copy(version_id)
      @item_type = Support.immutable_copy(item_type.to_s)
      @item_id = Support.immutable_copy(item_id)
      @recorded_at = Support.immutable_copy(recorded_at)
      @event = Support.immutable_copy(event&.to_s)
      @whodunnit = Support.immutable_copy(whodunnit)
      @record = RecordReference.new(type: @item_type, id: @item_id)
      freeze
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

    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        kind: kind,
        version_id: version_id,
        item_type: item_type,
        item_id: item_id,
        recorded_at: recorded_at
      }
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

    # Compares two reconstructed states and keeps them only when asked, which is
    # every caller's shape: the diff always comes from the pair, the pair itself
    # is retained on request.
    #: (from_boundary: ActivityBoundary, to_boundary: ActivityBoundary, from_snapshot: RecordSnapshot?, to_snapshot: RecordSnapshot?, retain: bool) -> ActivityStep
    def self.between(from_boundary:, to_boundary:, from_snapshot:, to_snapshot:, retain:)
      new(
        from_boundary: from_boundary,
        to_boundary: to_boundary,
        diff: Engine.compare(from_snapshot, to_snapshot),
        from_snapshot: (from_snapshot if retain),
        to_snapshot: (to_snapshot if retain)
      )
    end

    #: (from_boundary: ActivityBoundary, to_boundary: ActivityBoundary, diff: Diff, ?from_snapshot: RecordSnapshot?, ?to_snapshot: RecordSnapshot?) -> void
    def initialize(from_boundary:, to_boundary:, diff:, from_snapshot: nil, to_snapshot: nil)
      @from_boundary = from_boundary
      @to_boundary = to_boundary
      @diff = diff
      @from_snapshot = from_snapshot
      @to_snapshot = to_snapshot
      freeze
    end

    #: () -> bool
    def empty?
      diff.empty?
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        from: from_boundary.to_h,
        to: to_boundary.to_h,
        diff: diff.to_h
      }
    end
  end
end
