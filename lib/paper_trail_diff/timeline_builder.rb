# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects and compares a chronological slice of a record's version history.
  class TimelineBuilder
    #: (untyped, from: untyped, to: untyped, snapshotter: untyped) -> void
    def initialize(record, from:, to:, snapshotter:)
      @record = record
      @from = from
      @to = to
      @snapshotter = snapshotter
    end

    #: () -> Array[Step]
    def build
      versions = selected_versions
      snapshots = versions.map { |version| @snapshotter.call(version) }
      versions.each_cons(2).with_index.map do |version_pair, index|
        Step.new(
          from_version: version_pair.first,
          to_version: version_pair.last,
          diff: Engine.compare(snapshots.fetch(index), snapshots.fetch(index + 1))
        )
      end.freeze
    end

    private

    # @rbs @record: untyped
    # @rbs @from: untyped
    # @rbs @to: untyped
    # @rbs @snapshotter: untyped

    #: () -> Array[untyped]
    def selected_versions
      versions = versions_for_record
      from_index = boundary_index(versions, @from, boundary: :from)
      to_index = boundary_index(versions, @to, boundary: :to)
      if from_index > to_index
        raise InvalidTimelineRangeError, '`from` version must not follow `to` version'
      end

      versions.slice(from_index..to_index) || []
    end

    #: () -> Array[untyped]
    def versions_for_record
      association_name = @record.class.versions_association_name
      @record.public_send(association_name).reload.to_a
    rescue NoMethodError => e
      message = 'record does not expose a PaperTrail version history'
      raise InvalidTimelineRangeError, message, cause: e
    end

    #: (Array[untyped], untyped, boundary: Symbol) -> Integer
    def boundary_index(versions, requested, boundary:)
      index = versions.index { |version| same_version?(version, requested) }
      return index if index

      raise InvalidTimelineRangeError, "`#{boundary}` version is not in the record history"
    end

    #: (untyped, untyped) -> bool
    def same_version?(version, requested)
      version.instance_of?(requested.class) && version.id == requested.id
    rescue NoMethodError
      false
    end
  end
end
