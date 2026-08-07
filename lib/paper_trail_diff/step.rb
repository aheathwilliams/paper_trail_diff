# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # One adjacent transition in a PaperTrail timeline.
  class Step
    attr_reader :from_version #: untyped
    attr_reader :to_version #: untyped
    attr_reader :diff #: Diff

    #: (from_version: untyped, to_version: untyped, diff: Diff) -> void
    def initialize(from_version:, to_version:, diff:)
      @from_version = from_version
      @to_version = to_version
      @diff = diff
      freeze
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        from_version_id: from_version.id,
        to_version_id: to_version.id,
        diff: diff.to_h
      }
    end
  end
end
