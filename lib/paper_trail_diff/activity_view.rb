# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # How a request presents its activity steps: whether they keep their
  # snapshots, whether a transaction's steps merge into one, and which of
  # their versions' recorded changes they carry. Built and checked once per
  # request, and read the same way by both activity builders, or the same
  # history would read differently depending on how it was asked for.
  class ActivityView
    # Options only an activity view uses are refused without one.
    #: (activity: bool, snapshots: bool, group: Symbol?, recorded: IgnorePolicy?) -> ActivityView
    def self.build(activity:, snapshots:, group:, recorded:)
      view = new(snapshots: snapshots, group: group, recorded: recorded)
      return view if activity

      { snapshots: snapshots, recorded_changes: !recorded.nil?, group: !group.nil? }
        .each do |name, given|
          raise ConfigurationError, "#{name}: requires activity: true" if given
        end
      view
    end

    #: (?snapshots: bool, ?group: Symbol?, ?recorded: IgnorePolicy?) -> void
    def initialize(snapshots: false, group: nil, recorded: nil)
      unless group.nil? || group == :transaction
        raise ConfigurationError, 'group: must be :transaction or nil'
      end

      @snapshots = snapshots
      @group = group
      @recorded = recorded
      freeze
    end

    # Merging a group compares its outer states, so the snapshots must survive
    # the build even when the caller did not ask to keep them.
    #: () -> bool
    def retain?
      @snapshots || grouping?
    end

    # The attributes a boundary's version recorded, when they were asked for.
    #: (root: bool) -> Array[String]?
    def recorded_attributes(root:)
      @recorded&.recorded_attributes(root: root)
    end

    # Applied last, to finished steps, so grouping sees the same timeline the
    # caller would otherwise have received.
    #: (Array[ActivityStep]) -> Array[ActivityStep]
    def present(steps)
      return steps unless grouping?

      ActivityTransactionGrouper.new(steps, retain: @snapshots).call
    end

    private

    # @rbs @snapshots: bool
    # @rbs @group: Symbol?
    # @rbs @recorded: IgnorePolicy?

    #: () -> bool
    def grouping?
      @group == :transaction
    end
  end
end
