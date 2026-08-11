# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects an inclusive, chronological range from a record's root versions.
  class VersionRange
    #: (untyped, from: untyped, to: untyped, ?version_scope: untyped) -> void
    def initialize(record, from:, to:, version_scope: nil)
      @record = record
      @from = from
      @to = to
      @version_scope = version_scope
    end

    # Same selection as `select`, but keeping the step pairs a filter implies.
    #: () -> RootVersionPlan
    def select_plan_for_range
      relation = validated_relation
      select_plan(
        relation.where(created_at: @from.created_at..@to.created_at),
        through: @to
      )
    end

    #: () -> untyped
    def validated_relation
      relation = versions_relation
      validate_boundary!(@from, relation, boundary: :from)
      validate_boundary!(@to, relation, boundary: :to)
      if Support.compare_versions(@from, @to).positive?
        raise InvalidTimelineRangeError, '`from` version must not follow `to` version'
      end

      relation
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
    # @rbs @version_scope: untyped

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
      select_plan(relation, through: through).versions
    end

    #: (untyped, ?through: untyped) -> RootVersionPlan
    def select_plan(relation, through: nil)
      in_range = ordered(relation.to_a.select do |version|
        next false if Support.compare_versions(@from, version).positive?
        next true unless through

        Support.compare_versions(version, through) <= 0
      end)
      RootVersionSelection.new(
        in_range: in_range,
        selected: VersionScopeFilter.new(@version_scope).call(relation, in_range),
        after_range: nil,
        windowed: false,
        filtered: !@version_scope.nil?
      ).call
    end

    #: (Array[untyped]) -> Array[untyped]
    def ordered(versions)
      versions.sort_by { |version| Support.chronological_version_key(version) }
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
