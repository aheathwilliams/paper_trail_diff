# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Selects an inclusive, chronological range from a record's root versions.
  class VersionRange
    #: (untyped, from: untyped, to: untyped, version_scope: untyped) -> void
    def initialize(record, from:, to:, version_scope:)
      @record = record
      @from = from
      @to = to
      @version_scope = version_scope
    end

    # Keep both reconstruction boundaries and the step pairs a filter implies.
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
      relation = Endpoint.versions(@record)
      validate_boundary!(@from, relation, boundary: :from)
      validate_boundary!(@to, relation, boundary: :to)
      if Support.compare_versions(@from, @to).positive?
        raise InvalidTimelineRangeError, '`from` version must not follow `to` version'
      end

      relation
    end

    #: (untyped) -> RootVersionPlan
    def select_plan_through_current(current)
      Endpoint.validate_pair!(@record, current)
      relation = Endpoint.versions(@record)
      validate_boundary!(@from, relation, boundary: :from)
      select_plan(relation.where(created_at: @from.created_at..), live_endpoint: current)
    end

    private

    # @rbs @record: untyped
    # @rbs @from: untyped
    # @rbs @to: untyped
    # @rbs @version_scope: untyped

    #: (untyped, ?through: untyped, ?live_endpoint: untyped) -> RootVersionPlan
    def select_plan(relation, through: nil, live_endpoint: nil)
      in_range = ordered(relation.select do |version|
        Support.compare_versions(@from, version) <= 0 &&
          (!through || Support.compare_versions(version, through) <= 0)
      end)
      RootVersionSelection.new(
        in_range: in_range,
        selected: VersionScopeFilter.new(@version_scope).call(relation, in_range),
        after_range: nil,
        windowed: false,
        filtered: !@version_scope.nil?, live_endpoint: live_endpoint
      ).call
    end

    #: (Array[untyped]) -> Array[untyped]
    def ordered(versions)
      Support.chronological_sort(versions)
    end

    #: (untyped, untyped, boundary: Symbol) -> void
    def validate_boundary!(requested, relation, boundary:)
      return if valid_boundary?(requested, relation)

      raise InvalidTimelineRangeError, "`#{boundary}` version is not in the record history"
    end

    # The relation holds only this record's versions, so finding the id there
    # also settles which record the version belongs to.
    #: (untyped, untyped) -> bool
    def valid_boundary?(requested, relation)
      requested.instance_of?(relation.klass) && relation.exists?(requested.id)
    end
  end
end
