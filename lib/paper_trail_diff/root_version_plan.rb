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
    # The root versions this plan reports as mutations, which excludes any
    # version present only to reveal what the last of them produced.
    attr_reader :mutations #: Array[untyped]

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
    end

    #: (versions: Array[untyped], steps: Array[[untyped, untyped]], ?context_version: untyped, ?reconstruction_versions: Array[untyped]?, ?mutations: Array[untyped]?) -> void
    def initialize(
      versions:, steps:, context_version: nil, reconstruction_versions: nil, mutations: nil
    )
      @versions = versions.freeze
      @reconstruction_versions = (reconstruction_versions || versions).freeze
      @steps = steps.freeze
      @context_version = context_version
      @mutations = (mutations || default_mutations).freeze
      @mutation_keys = Set.new(@mutations.map { |version| key(version) }).freeze
      freeze
    end

    #: () -> bool
    def empty?
      versions.empty?
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

    #: (untyped) -> Array[untyped]
    def key(version)
      [version.class.name, version.id]
    end
  end
end
