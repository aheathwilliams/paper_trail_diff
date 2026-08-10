# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Carries one collection event through recursive immutable route replacement.
  class ActivityCollectionRouteChange
    attr_reader :route #: Array[untyped]
    attr_reader :version #: untyped
    attr_reader :record #: untyped
    attr_reader :replacement #: RecordSnapshot?

    #: (route: Array[untyped], version: untyped, record: untyped, replacement: RecordSnapshot?) -> void
    def initialize(route:, version:, record:, replacement:)
      @route = route
      @version = version
      @record = record
      @replacement = replacement
      freeze
    end
  end
end
