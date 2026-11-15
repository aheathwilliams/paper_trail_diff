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
    #: (activity: bool, snapshots: bool, group: Symbol?, recorded: IgnorePolicy?, ?version_scope: untyped) -> ActivityView
    def self.build(activity:, snapshots:, group:, recorded:, version_scope: nil)
      Support.boolean!(:activity, activity)
      Support.boolean!(:snapshots, snapshots)
      view = new(snapshots: snapshots, group: group, recorded: recorded,
                 version_scope: version_scope)
      return view if activity

      { snapshots: snapshots, recorded_changes: !recorded.nil?, group: !group.nil? }
        .each do |name, given|
          raise ConfigurationError, "#{name}: requires activity: true" if given
        end
      view
    end

    #: (?snapshots: bool, ?group: Symbol?, ?recorded: IgnorePolicy?, ?version_scope: untyped) -> void
    def initialize(snapshots: false, group: nil, recorded: nil, version_scope: nil)
      unless group.nil? || group == :transaction
        raise ConfigurationError, 'group: must be :transaction or nil'
      end

      @snapshots = snapshots
      @group = group
      @readers = recorded && [true, false].to_h do |root|
        [root, RecordedChangesReader.new(recorded.recorded_attributes(root: root))]
      end
      @version_filter = version_scope && ActivityScopeFilter.new(version_scope)
      freeze
    end

    # Which events of activity on associations a `version_scope:` reports,
    # answered once for the whole request; nil without one.
    attr_reader :version_filter #: ActivityScopeFilter?

    # Merging a group compares its outer states, so the snapshots must survive
    # the build even when the caller did not ask to keep them.
    #: () -> bool
    def retain?
      @snapshots || grouping?
    end

    # Reads what a boundary's version recorded, once per version for the whole
    # request, when they were asked for. The root's own versions leave out the
    # names ignored on its path as well.
    #: (root: bool) -> RecordedChangesReader?
    def recorded_reader(root:)
      @readers&.fetch(root)
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
    # @rbs @readers: Hash[bool, RecordedChangesReader]?
    # @rbs @version_filter: ActivityScopeFilter?

    #: () -> bool
    def grouping?
      @group == :transaction
    end
  end
end
