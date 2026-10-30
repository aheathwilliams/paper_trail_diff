# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Shared by the two activity builders. They differ in how they choose
  # boundaries -- one from an explicit version range, one from a wall-clock
  # window -- but a transaction has to collapse the same way in both, or the
  # same history would read differently depending on how it was asked for.
  module ActivityGrouping
    #: (Symbol?, ?activity: bool, ?snapshots: bool, ?recorded_changes: bool) -> void
    def self.validate!(group, activity: true, snapshots: false, recorded_changes: false)
      unless group.nil? || group == :transaction
        raise ConfigurationError, 'group: must be :transaction or nil'
      end
      return if activity

      { snapshots: snapshots, recorded_changes: recorded_changes, group: !group.nil? }
        .each do |name, given|
          raise ConfigurationError, "#{name}: requires activity: true" if given
        end
    end

    private

    #: () -> bool
    def grouping?
      @group == :transaction
    end

    # Applied last, to finished steps, so grouping sees the same timeline the
    # caller would otherwise have received.
    #: (Array[ActivityStep]) -> Array[ActivityStep]
    def group_steps(steps)
      return steps unless grouping?

      ActivityTransactionGrouper.new(steps, retain: @snapshots).call
    end
  end
end
