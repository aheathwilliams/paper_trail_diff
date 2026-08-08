# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Endpoint and root-checkpoint timeline results built from one normalized history.
  class Analysis
    attr_reader :diff #: Diff
    attr_reader :timeline #: Array[Step]

    #: (diff: Diff, timeline: Array[Step]) -> void
    def initialize(diff:, timeline:)
      @diff = diff
      @timeline = timeline.dup.freeze
      freeze
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      { diff: diff.to_h, timeline: Support.serialize(timeline) }
    end
  end
end
