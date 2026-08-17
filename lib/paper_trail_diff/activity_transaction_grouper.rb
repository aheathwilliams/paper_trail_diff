# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reports one saved transaction as one activity step.
  #
  # A parent and its children saved together produce a version each, and the
  # timeline reports the gap between every pair of them. One deliberate action
  # therefore arrives as several steps, none of which is the thing the person
  # did.
  #
  # A version records the state before its own event. Two things follow.
  #
  # The change a step reports was made by the event that *opens* it, so a step
  # belongs to the transaction of its `from_boundary`, and consecutive steps
  # sharing one are the parts of a single save. Grouping on the closing boundary
  # instead would credit each change to whoever made the next one.
  #
  # And a child's new value is revealed only by something later -- a further
  # version of that child, its destroy version, or the live row. Inside a
  # transaction there is usually none of those yet, so a step can read as empty
  # while a change was in fact made at that boundary, and the change surfaces
  # later, folded in with whatever that step carried. Grouping puts it back
  # together with the save it belongs to.
  #
  # Merging compares the group's outer snapshots rather than combining the
  # diffs between them. A field set and then restored inside one transaction
  # has not changed, and only a comparison of the endpoints can say so.
  #
  # A boundary with no transaction groups with nothing. PaperTrail leaves the
  # column nil outside a transaction, and a custom version class need not carry
  # it at all; treating those as one shared transaction would merge unrelated
  # history into a single step.
  class ActivityTransactionGrouper
    #: (Array[ActivityStep], retain: bool) -> void
    def initialize(steps, retain:)
      @steps = steps
      @retain = retain
    end

    #: () -> Array[ActivityStep]
    def call
      grouped = [] #: Array[Array[ActivityStep]]
      @steps.each do |step|
        open_group = grouped.last
        if open_group && continues?(open_group, step)
          open_group << step
        else
          grouped << [step]
        end
      end
      grouped.map { |group| merge(group) }
    end

    private

    # @rbs @steps: Array[ActivityStep]
    # @rbs @retain: bool

    #: (Array[ActivityStep], ActivityStep) -> bool
    def continues?(open_group, step)
      transaction = step.from_boundary.transaction_id
      return false if transaction.nil?

      open_group.last.from_boundary.transaction_id == transaction
    end

    # Rebuilt rather than reused even when a group holds one step, so that every
    # returned step retains its snapshots on the same terms.
    #: (Array[ActivityStep]) -> ActivityStep
    def merge(group)
      first = group.first #: ActivityStep
      last = group.last #: ActivityStep
      ActivityStep.between(
        from_boundary: first.from_boundary,
        to_boundary: last.to_boundary,
        from_snapshot: first.from_snapshot,
        to_snapshot: last.to_snapshot,
        retain: @retain
      )
    end
  end
end
