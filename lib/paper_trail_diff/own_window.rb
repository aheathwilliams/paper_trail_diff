# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Splits the versions read for a batch by each root's own window. A
  # transaction that crosses an edge moves a root's window to start or end
  # earlier (see TransactionCut), never later, so the versions read from the
  # earliest start to the shared end hold each root's own, and the first left
  # past an end that moved.
  module OwnWindow
    # From the earliest start to the shared end.
    #: (TimeRange, Array[TimeRange]) -> TimeRange
    def self.widest(range, windows)
      start = [range.begin_time, *windows.map(&:begin_time)].min
      TimeRange.new(range.exclude_end? ? (start...range.end_time) : (start..range.end_time))
    end

    # The versions inside `window`, and the first of the rest past its end.
    # They are read in no order, so the first is found by time and id.
    #: (TimeRange, Array[untyped]) -> [Array[untyped], untyped]
    def self.split(window, loaded)
      own, rest = loaded.partition { |version| window.include?(version.created_at) }
      [own, first_past(rest, window.end_time)]
    end

    #: (Array[untyped], Time?) -> untyped
    def self.first_past(versions, finish)
      return unless finish

      versions.select { |version| version.created_at >= finish }
              .min_by { |version| Support.chronological_version_key(version) }
    end
    private_class_method :first_past
  end
end
