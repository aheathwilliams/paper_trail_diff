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
    # Requested missing-root analyses, kept separate because live SQL conditions
    # cannot prove which deleted rows matched. nil means no destroy history.
    attr_reader :deleted #: Hash[Array[String], Analysis?]

    #: (analyses: Hash[Array[String], Analysis], unreachable: Array[Array[String]], ?roots: Array[untyped], ?deleted: Hash[Array[String], Analysis?]) -> void
    def initialize(analyses:, unreachable:, roots: [], deleted: {})
      @analyses = analyses
      @unreachable = Support.immutable_copy(unreachable)
      # Not deep-copied: these are the caller's own model instances, and
      # freezing them would make an ordinary `record.title` on a lazy attribute
      # fail. The array itself is frozen so the collection cannot be reshaped.
      @roots = roots.dup.freeze
      @deleted = Support.immutable_copy(deleted)
      freeze
    end

    # Each root's change rows, keyed as `analyses` is: the roots that still
    # exist, then the deleted ones that have history to report. A deleted root
    # without destroy history has no rows and is left out.
    #: () -> Hash[Array[String], Array[ChangeRow]]
    def change_rows
      rows = {} #: Hash[Array[String], Array[ChangeRow]]
      analyses.each { |identity, analysis| rows[identity] = analysis.change_rows }
      deleted.each { |identity, analysis| rows[identity] = analysis.change_rows if analysis }
      rows.freeze
    end

    # Two elements, not three: `roots` is reached by name so that existing
    # destructuring keeps working.
    #: () -> [Hash[Array[String], Analysis], Array[Array[String]]]
    def to_ary
      [analyses, unreachable]
    end
  end
end
