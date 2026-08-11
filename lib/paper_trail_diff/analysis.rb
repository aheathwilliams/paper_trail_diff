# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Endpoint and root-checkpoint timeline results built from one normalized history.
  class Analysis
    attr_reader :diff #: Diff
    attr_reader :timeline #: Array[Step]
    attr_reader :activity_timeline #: Array[ActivityStep]?

    # The result for a record whose requested history contains no versions,
    # which is an empty history rather than a failed request.
    #: () -> Analysis
    def self.empty
      timeline = [] #: Array[Step]
      activity_timeline = [] #: Array[ActivityStep]
      new(diff: Diff.new, timeline: timeline, activity_timeline: activity_timeline)
    end

    #: (diff: Diff, timeline: Array[Step], ?activity_timeline: Array[ActivityStep]?) -> void
    def initialize(diff:, timeline:, activity_timeline: nil)
      @diff = diff
      @timeline = timeline.dup.freeze
      @activity_timeline = activity_timeline&.dup&.freeze
      freeze
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      value = { diff: diff.to_h, timeline: Support.serialize(timeline) }
      value[:activity_timeline] = Support.serialize(activity_timeline) if activity_timeline
      value
    end
  end
end
