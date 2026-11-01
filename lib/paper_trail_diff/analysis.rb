# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Endpoint and root-checkpoint timeline results built from one normalized history.
  class Analysis
    attr_reader :diff #: Diff
    attr_reader :timeline #: Array[Step]
    attr_reader :activity_timeline #: Array[ActivityStep]?
    attr_reader :from_snapshot #: RecordSnapshot?
    attr_reader :to_snapshot #: RecordSnapshot?
    # The time window the analysis covers, or nil without one. It is the
    # window asked for unless a transaction crossed an edge, which moves the
    # edge back to where that transaction began.
    attr_reader :window #: Range[Time]?

    # The result for a record whose requested history contains no versions,
    # which is an empty history rather than a failed request. Its snapshots
    # are nil because no state was read, not because the record was absent:
    # reading one would rebuild the whole graph, per record in a batch. Its
    # activity timeline is empty when activity was asked for and nil when not,
    # as a record with versions would have.
    #: (?activity: bool) -> Analysis
    def self.empty(activity: true)
      timeline = [] #: Array[Step]
      activity_timeline = [] #: Array[ActivityStep]
      new(diff: Diff.new, timeline: timeline, activity_timeline: (activity_timeline if activity))
    end

    # The reconstructed states the diff was taken between. A report that has to
    # render unchanged columns needs the whole final state, not only what moved.
    #: (diff: Diff, timeline: Array[Step], ?activity_timeline: Array[ActivityStep]?, ?from_snapshot: RecordSnapshot?, ?to_snapshot: RecordSnapshot?, ?window: Range[Time]?) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      diff:, timeline:, activity_timeline: nil, from_snapshot: nil, to_snapshot: nil, window: nil
    )
      @diff = diff
      @timeline = timeline.dup.freeze
      @activity_timeline = activity_timeline&.dup&.freeze
      @from_snapshot = from_snapshot
      @to_snapshot = to_snapshot
      @window = window
      freeze
    end

    # The same result for the window it was read in, which the caller knows
    # once it has moved the window's edges to transactions.
    #: (TimeRange?) -> Analysis
    def with_window(range)
      self.class.new(
        diff: diff, timeline: timeline, activity_timeline: activity_timeline,
        from_snapshot: from_snapshot, to_snapshot: to_snapshot, window: range&.to_range
      )
    end

    # Every activity step's rows, in time order. Only the activity timeline says
    # who made each change, so an analysis built without it has no rows to give.
    #: () -> Array[ChangeRow]
    def change_rows
      steps = activity_timeline
      raise ConfigurationError, 'change_rows requires activity: true' unless steps

      steps.flat_map(&:change_rows).freeze
    end

    # Reconstructed endpoint states are opt-in, because they carry the whole
    # selected graph whether or not anything changed, which dwarfs the rest of
    # the payload for a wide graph.
    #: (?snapshots: bool, ?metadata: bool) -> Hash[Symbol, untyped]
    def to_h(snapshots: false, metadata: false)
      value = { diff: diff.to_h, timeline: timeline.map { |step| step.to_h(metadata: metadata) } }
      activity = activity_timeline
      if activity
        value[:activity_timeline] = activity.map do |step|
          step.to_h(metadata: metadata, snapshots: snapshots)
        end
      end
      return value unless snapshots

      value.merge(
        from_snapshot: Support.serialize(from_snapshot),
        to_snapshot: Support.serialize(to_snapshot)
      )
    end
  end
end
