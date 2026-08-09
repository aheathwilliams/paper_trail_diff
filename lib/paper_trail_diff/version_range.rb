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
      relation = versions_relation
      validate_boundary!(@from, relation, boundary: :from)
      validate_boundary!(@to, relation, boundary: :to)
      if Support.compare_versions(@from, @to).positive?
        raise InvalidTimelineRangeError, '`from` version must not follow `to` version'
      end

      select_relation(
        relation.where(created_at: @from.created_at..@to.created_at),
        through: @to
      )
    end

    #: () -> Array[untyped]
    def select_through_latest
      relation = versions_relation
      validate_boundary!(@from, relation, boundary: :from)
      select_relation(relation.where(created_at: @from.created_at..))
    end

    private

    # @rbs @record: untyped
    # @rbs @from: untyped
    # @rbs @to: untyped

    #: () -> untyped
    def versions_relation
      association_name = @record.class.versions_association_name
      @record.public_send(association_name)
    rescue NoMethodError => e
      message = 'record does not expose a PaperTrail version history'
      raise InvalidTimelineRangeError, message, cause: e
    end

    #: (untyped, ?through: untyped) -> Array[untyped]
    def select_relation(relation, through: nil)
      selected = relation.to_a.select do |version|
        next false if Support.compare_versions(@from, version).positive?
        next true unless through

        Support.compare_versions(version, through) <= 0
      end
      selected.sort_by { |version| Support.chronological_version_key(version) }
    end

    #: (untyped, untyped, boundary: Symbol) -> void
    def validate_boundary!(requested, relation, boundary:)
      Endpoint.validate!(requested)
      return if valid_boundary?(requested, relation)

      raise InvalidTimelineRangeError, "`#{boundary}` version is not in the record history"
    rescue InvalidEndpointError, NoMethodError
      raise InvalidTimelineRangeError, "`#{boundary}` version is not in the record history"
    end

    #: (untyped, untyped) -> bool
    def valid_boundary?(requested, relation)
      expected_identity = [@record.class.base_class.name.to_s, @record.id.to_s]
      Endpoint.version?(requested) &&
        requested.instance_of?(relation.klass) &&
        Endpoint.identity(requested) == expected_identity &&
        relation.where(id: requested.id).exists?
    end
  end
end
