# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects an inclusive, chronological range from a record's root versions.
  class VersionRange
    #: (untyped, from: untyped, to: untyped) -> void
    def initialize(record, from:, to:)
      @record = record
      @from = from
      @to = to
    end

    #: () -> Array[untyped]
    def select
      versions = versions_for_record
      from_index = boundary_index(versions, @from, boundary: :from)
      to_index = boundary_index(versions, @to, boundary: :to)
      if from_index > to_index
        raise InvalidTimelineRangeError, '`from` version must not follow `to` version'
      end

      versions.slice(from_index..to_index) || []
    end

    private

    # @rbs @record: untyped
    # @rbs @from: untyped
    # @rbs @to: untyped

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
