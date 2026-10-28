# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Which versions a range reconstructs, and which pairs of them become steps.
  #
  # Without a filter those are the same thing: every selected version is a
  # boundary and adjacent ones bound each other. A filter separates them, because
  # each selected mutation then has to be bounded by the version that actually
  # reveals it rather than by the next mutation that happened to be selected.
  #
  # A filter also separates what is *reported* from what has to be *replayed*.
  # The activity view rebuilds state by carrying one snapshot forward across
  # every event in order, so skipping a filtered-out version would leave that
  # snapshot holding a state the record had already moved past. `versions` are
  # the boundaries the steps refer to; `reconstruction_versions` are every root
  # version the span passes through, which is what any forward replay must walk.
  class RootVersionPlan
    attr_reader :versions #: Array[untyped]
    attr_reader :reconstruction_versions #: Array[untyped]
    attr_reader :steps #: Array[[untyped, untyped]]
    attr_reader :context_version #: untyped
    # The live record a window closes on when no later version can reveal its
    # final mutation. It is a boundary, never a version, so it stays out of
    # `versions` and out of anything that reconstructs from version history.
    attr_reader :closing_record #: untyped
    # The root versions this plan reports as mutations, which excludes any
    # version present only to reveal what the last of them produced.
    attr_reader :mutations #: Array[untyped]
    # Whether a wall-clock window closes on the root's own destruction. Its
    # final state is then the absence the destroy left, just as a window
    # closing on current state ends at the live record.
    attr_reader :closes_on_destroy #: bool

    class << self
      # Adjacent boundaries, which is what an unfiltered range reports.
      #: (Array[untyped], ?context_version: untyped) -> RootVersionPlan
      def contiguous(versions, context_version: nil)
        new(
          versions: versions,
          steps: versions.each_cons(2).map { |from, to| [from, to] },
          context_version: context_version
        )
      end

      #: () -> RootVersionPlan
      def empty
        versions = [] #: Array[untyped]
        steps = [] #: Array[[untyped, untyped]]
        new(versions: versions, steps: steps)
      end

      # No root version to report or replay: only descendants moved, and the
      # live record is the root's state throughout.
      #: (untyped) -> RootVersionPlan
      def closing_on(record)
        versions = [] #: Array[untyped]
        steps = [] #: Array[[untyped, untyped]]
        new(versions: versions, steps: steps, closing_record: record)
      end
    end

    #: (versions: Array[untyped], steps: Array[[untyped, untyped]], ?context_version: untyped, ?reconstruction_versions: Array[untyped]?, ?mutations: Array[untyped]?, ?closing_record: untyped, ?closes_on_destroy: bool) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      versions:, steps:, context_version: nil, reconstruction_versions: nil, mutations: nil,
      closing_record: nil, closes_on_destroy: false
    )
      @closing_record = closing_record
      @closes_on_destroy = closes_on_destroy
      @versions = versions.freeze
      @reconstruction_versions = (reconstruction_versions || versions).freeze
      @steps = steps.freeze
      @context_version = context_version
      @mutations = (mutations || default_mutations).freeze
      @mutation_keys = key_set(@mutations)
      freeze
    end

    #: () -> bool
    def empty?
      versions.empty?
    end

    #: () -> RootVersionPlan
    def closing_on_destroy
      self.class.new(
        versions: versions, steps: steps, context_version: context_version,
        reconstruction_versions: reconstruction_versions, mutations: mutations,
        closing_record: closing_record, closes_on_destroy: true
      )
    end

    # What the range's final state is read from, which is the live record when
    # the window closes on current state and the last version otherwise.
    #: () -> untyped
    def final_endpoint
      @closing_record || @versions.last
    end

    #: (untyped) -> bool
    def mutation?(version)
      @mutation_keys.include?(key(version))
    end

    private

    # @rbs @mutation_keys: Set[Array[untyped]]

    #: () -> Array[untyped]
    def default_mutations
      return @versions unless @context_version

      context = key(@context_version)
      @versions.reject { |version| key(version) == context }
    end

    # A Set only makes the lookup in `mutation?` fast; an Array would answer the
    # same, which is why mutant leaves this alone.
    # mutant:disable
    #: (Array[untyped]) -> Set[Array[untyped]]
    def key_set(versions)
      Set.new(versions.map { |version| key(version) })
    end

    # By class name, so a version still matches after its class is reloaded.
    #: (untyped) -> Array[untyped]
    def key(version)
      [version.class.name, version.id]
    end
  end
end
