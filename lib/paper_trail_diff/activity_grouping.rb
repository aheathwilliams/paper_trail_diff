# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Shared by the two activity builders. They differ in how they choose
  # boundaries -- one from an explicit version range, one from a wall-clock
  # window -- but a transaction has to collapse the same way in both, or the
  # same history would read differently depending on how it was asked for.
  module ActivityGrouping
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
