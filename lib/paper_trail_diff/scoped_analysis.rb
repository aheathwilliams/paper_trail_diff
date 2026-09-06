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
    # The live records the selection loaded, in the order it loaded them. The
    # gem already has them; withholding them only makes a caller query the same
    # rows again to attach its own presentation data. A destroyed root has no
    # record to hand back, so `roots` and `unreachable` stay complementary.
    attr_reader :roots #: Array[untyped]

    #: (analyses: Hash[Array[String], Analysis], unreachable: Array[Array[String]], ?roots: Array[untyped]) -> void
    def initialize(analyses:, unreachable:, roots: [])
      @analyses = analyses
      @unreachable = Support.immutable_copy(unreachable)
      # Not deep-copied: these are the caller's own model instances, and
      # freezing them would make an ordinary `record.title` on a lazy attribute
      # fail. The array itself is frozen so the collection cannot be reshaped.
      @roots = roots.dup.freeze
      freeze
    end

    # Two elements, not three: `roots` is reached by name so that existing
    # destructuring keeps working.
    #: () -> [Hash[Array[String], Analysis], Array[Array[String]]]
    def to_ary
      [analyses, unreachable]
    end
  end
end
