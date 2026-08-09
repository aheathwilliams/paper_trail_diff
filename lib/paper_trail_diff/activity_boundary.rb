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

    #: (from_boundary: ActivityBoundary, to_boundary: ActivityBoundary, diff: Diff) -> void
    def initialize(from_boundary:, to_boundary:, diff:)
      @from_boundary = from_boundary
      @to_boundary = to_boundary
      @diff = diff
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
