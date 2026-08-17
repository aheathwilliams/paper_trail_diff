# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # What the relation form of `analyze_many` returns: the analyses, plus the
  # roots the relation could not reach.
  #
  # `to_ary` is defined so the pair destructures, which keeps the common case
  # reading like the plain Hash the record form returns:
  #
  #   analyses, unreachable = PaperTrailDiff.analyze_many(scope: ..., limit: 500)
  #
  # It deliberately does not pretend to be a Hash beyond that. Somebody
  # iterating this object should have to decide which half they meant.
  class ScopedAnalysis
    attr_reader :analyses #: Hash[Array[String], Analysis]
    attr_reader :unreachable #: Array[Array[String]]

    #: (analyses: Hash[Array[String], Analysis], unreachable: Array[Array[String]]) -> void
    def initialize(analyses:, unreachable:)
      @analyses = analyses
      @unreachable = Support.immutable_copy(unreachable)
      freeze
    end

    #: () -> [Hash[Array[String], Analysis], Array[Array[String]]]
    def to_ary
      [analyses, unreachable]
    end
  end
end
