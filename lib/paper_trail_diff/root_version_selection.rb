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
    INCOMPLETE = 'time range requires a later root version to reconstruct its final change'

    #: (in_range: Array[untyped], selected: Array[untyped], after_range: untyped, windowed: bool, ?context_required: bool) -> void
    def initialize(in_range:, selected:, after_range:, windowed:, context_required: false)
      @in_range = in_range
      @selected = selected
      @after_range = after_range
      @windowed = windowed
      @context_required = context_required
    end

    # Returns the versions to reconstruct from, and which of them is present
    # only as context. A caller that reports mutations needs to tell them apart.
    #: () -> [Array[untyped], untyped]
    def call
      return without_selection if @selected.empty?

      revealing = revealing_version
      return [(@selected + [revealing]).freeze, revealing] if revealing
      return [@selected.freeze, nil] if !@windowed || terminal_destroy?

      raise IncompleteTimeRangeError, INCOMPLETE
    end

    private

    # @rbs @in_range: Array[untyped]
    # @rbs @selected: Array[untyped]
    # @rbs @after_range: untyped
    # @rbs @windowed: bool
    # @rbs @context_required: bool

    # An activity view still needs a root to reconstruct from even when no root
    # version falls inside the window, because descendants may have moved.
    #: () -> [Array[untyped], untyped]
    def without_selection
      empty = [] #: Array[untyped]
      return [empty.freeze, nil] unless @context_required
      return [[@after_range].freeze, @after_range] if @after_range

      raise IncompleteTimeRangeError, INCOMPLETE
    end

    # A version left out by a filter is still the state the last selected change
    # produced, so it is preferred over anything after the range.
    #: () -> untyped
    def revealing_version
      last = @selected.last
      within = @in_range.find do |version|
        Support.compare_versions(last, version).negative?
      end
      within || @after_range
    end

    # A range closing on the record's own destruction needs no later version:
    # nothing can follow it, so demanding one would reject the range forever.
    #: () -> bool
    def terminal_destroy?
      @selected.last&.event.to_s == 'destroy'
    end
  end
end
