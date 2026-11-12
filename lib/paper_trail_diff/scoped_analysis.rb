# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # What `analyze_scope` and `report` return: the analyses, plus the roots the
  # relation could not reach.
  #
  # `to_ary` is defined so the pair destructures, which keeps the common case
  # reading like the plain Hash `analyze_many` returns:
  #
  #   analyses, unreachable = PaperTrailDiff.analyze_scope(Article.all, limit: 500)
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
      each_root(&:change_rows)
    end

    # The analysis of one of `roots`, found from the record itself. The keys
    # are its base class's name and its ID as a string, which a subclass or an
    # integer ID gets wrong when built by hand. Raises KeyError for a record
    # the selection did not load; a deleted root's analysis is in `deleted`.
    #: (untyped) -> Analysis
    def analysis_for(record)
      analyses.fetch(Endpoint.identity(record))
    end

    # Each root's net changes, keyed as `change_rows` is; the block picks the
    # rows to keep, as for Analysis#net_changes.
    #: () ?{ (ChangeRow) -> boolish } -> Hash[Array[String], Array[NetChange]]
    def net_changes(&keep)
      each_root { |analysis| analysis.net_changes(&keep) }
    end

    # Two elements, not three: `roots` is reached by name so that existing
    # destructuring keeps working.
    #: () -> [Hash[Array[String], Analysis], Array[Array[String]]]
    def to_ary
      [analyses, unreachable]
    end

    private

    # What the block makes of each root's analysis: the roots that still
    # exist, then the deleted ones that have history to report.
    #: [T] () { (Analysis) -> T } -> Hash[Array[String], T]
    def each_root(&block)
      reported = deleted.filter_map { |identity, analysis| [identity, analysis] if analysis }
      analyses.merge(reported.to_h).transform_values(&block).freeze
    end
  end
end
