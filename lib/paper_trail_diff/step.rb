# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # One adjacent transition in a PaperTrail timeline.
  class Step
    attr_reader :from_version #: untyped
    attr_reader :to_version #: untyped
    attr_reader :from_boundary #: ActivityBoundary
    attr_reader :to_boundary #: ActivityBoundary
    attr_reader :diff #: Diff

    # `to_version` is nil for the one step that closes on current state, which a
    # window reaching past the last recorded version has to do. Read
    # `to_boundary` instead when a caller may have opted into that.
    #: (from_version: untyped, to_version: untyped, diff: Diff, ?captured_at: untyped) -> void
    def initialize(from_version:, to_version:, diff:, captured_at: nil)
      live = Endpoint.record?(to_version)
      @from_version = from_version
      @to_version = (to_version unless live)
      @from_boundary = ActivityBoundary.from_version(from_version)
      @to_boundary = if live
                       ActivityBoundary.current(to_version, captured_at: captured_at)
                     else
                       ActivityBoundary.from_version(to_version)
                     end
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
        from_version_id: from_version.id,
        to_version_id: to_version&.id,
        to_boundary: to_boundary.to_h,
        diff: diff.to_h
      }
    end
  end
end
