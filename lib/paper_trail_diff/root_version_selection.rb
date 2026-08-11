# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Decides which versions a range reports, and which one reveals the last of
  # them. A version records the state before its own event, so whatever follows
  # the final selected mutation is the only thing that can show what it produced.
  # That successor is reconstruction context rather than a reported mutation, so
  # a filter must never remove it.
  #
  # Both the single-record and the batched selectors resolve this here, because
  # the rule is subtle enough that two copies of it would drift apart.
  class RootVersionSelection
    # An error is a specification, so it names the way out as well as the wall.
    # A window ending at the present can never gain a later version, which makes
    # "write a checkpoint afterwards" impossible advice on its own.
    INCOMPLETE = 'time range requires a later root version to reconstruct its ' \
                 'final change: pass close_on: :current to end at current state, ' \
                 'or narrow the window to end before the last recorded version'

    #: (in_range: Array[untyped], selected: Array[untyped], after_range: untyped, windowed: bool, ?context_required: bool, ?filtered: bool, ?live_endpoint: untyped) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      in_range:, selected:, after_range:, windowed:, context_required: false, filtered: false,
      live_endpoint: nil
    )
      @in_range = in_range
      @selected = selected
      @after_range = after_range
      @windowed = windowed
      @context_required = context_required
      @filtered = filtered
      @live_endpoint = live_endpoint
    end

    #: () -> RootVersionPlan
    def call
      return without_selection if @selected.empty?

      closing = revealing_version || @live_endpoint
      raise IncompleteTimeRangeError, INCOMPLETE if !closing && @windowed && !terminal_destroy?
      return filtered_plan(closing) if @filtered

      contiguous_plan(closing)
    end

    private

    # @rbs @in_range: Array[untyped]
    # @rbs @selected: Array[untyped]
    # @rbs @after_range: untyped
    # @rbs @windowed: bool
    # @rbs @context_required: bool
    # @rbs @filtered: bool
    # @rbs @live_endpoint: untyped

    # A window reaching past the last recorded version has only the live record
    # left to show what its final mutation produced. That record is a closing
    # boundary rather than a selected mutation, so it never joins `versions`.
    #: (untyped) -> RootVersionPlan
    def contiguous_plan(closing)
      return RootVersionPlan.contiguous(@selected) unless closing
      unless Endpoint.record?(closing)
        return RootVersionPlan.contiguous(@selected + [closing], context_version: closing)
      end

      steps = @selected.each_cons(2).map { |from, to| [from, to] } #: Array[[untyped, untyped]]
      steps << [@selected.last, closing]
      RootVersionPlan.new(versions: @selected, steps: steps, closing_record: closing)
    end

    # An activity view still needs a root to reconstruct from even when no root
    # version falls inside the window, because descendants may have moved.
    #: () -> RootVersionPlan
    def without_selection
      return RootVersionPlan.empty unless @context_required
      if @after_range
        return RootVersionPlan.contiguous([@after_range], context_version: @after_range)
      end

      raise IncompleteTimeRangeError, INCOMPLETE
    end

    # Each selected mutation is bounded by the version that reveals it, not by
    # the next mutation that happened to be selected. Bounding by the next
    # selection would fold anything filtered out in between into it, so the same
    # edit would read differently depending on what followed it.
    #: (untyped) -> RootVersionPlan
    def filtered_plan(revealing)
      steps = @selected.filter_map do |version|
        successor = version.equal?(@selected.last) ? revealing : immediate_successor(version)
        [version, successor] if successor
      end #: Array[[untyped, untyped]]
      filtered_plan_for(steps, revealing)
    end

    #: (Array[[untyped, untyped]], untyped) -> RootVersionPlan
    def filtered_plan_for(steps, revealing)
      live = revealing if Endpoint.record?(revealing)
      versions = chronological(
        (steps.flatten(1) + closing_versions).reject { |entry| Endpoint.record?(entry) }
      )
      RootVersionPlan.new(
        versions: versions, steps: steps,
        context_version: (revealing unless live),
        reconstruction_versions: spanned(versions),
        mutations: @selected, closing_record: live
      )
    end

    # Nothing can follow a destroy, so it never pairs into a step. It is still a
    # selected mutation, and the activity view closes on the absence it leaves,
    # so it has to stay a boundary or a filtered report loses the deletion
    # entirely — the one event it can least afford to drop.
    #: () -> Array[untyped]
    def closing_versions
      terminal_destroy? ? [@selected.last] : []
    end

    # Everything the span passes through, filtered out or not. A replay that
    # skipped the excluded versions would carry a stale state into the next
    # reported step, so the two selected mutations either side of a gap would
    # disagree about what the record looked like between them.
    #: (Array[untyped]) -> Array[untyped]
    def spanned(versions)
      first = versions.first
      last = versions.last
      return versions unless first && last

      @in_range.select do |candidate|
        !Support.compare_versions(first, candidate).positive? &&
          !Support.compare_versions(candidate, last).positive?
      end
    end

    #: (Array[untyped]) -> Array[untyped]
    def chronological(versions)
      versions.uniq { |version| [version.class.name, version.id] }
              .sort_by { |version| Support.chronological_version_key(version) }
    end

    #: (untyped) -> untyped
    def immediate_successor(version)
      @in_range.find { |candidate| Support.compare_versions(version, candidate).negative? }
    end

    # A version left out by a filter is still the state the last selected change
    # produced, so it is preferred over anything after the range.
    #: () -> untyped
    def revealing_version
      immediate_successor(@selected.last) || @after_range
    end

    # A range closing on the record's own destruction needs no later version:
    # nothing can follow it, so demanding one would reject the range forever.
    #: () -> bool
    def terminal_destroy?
      @selected.last&.event.to_s == 'destroy'
    end
  end
end
