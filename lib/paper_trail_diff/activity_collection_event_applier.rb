# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Applies a safe collection event across every selected route for its record type.
  class ActivityCollectionEventApplier
    #: (record_resolver: ActivityEventRecordResolver, record_normalizer: ActivityEventRecordNormalizer, route_updater: ActivityCollectionRouteUpdater, relationship: ActivityRelationship) -> void
    def initialize(record_resolver:, record_normalizer:, route_updater:, relationship:)
      @record_resolver = record_resolver
      @record_normalizer = record_normalizer
      @route_updater = route_updater
      @relationship = relationship
    end

    #: (Array[Array[untyped]], untyped, ActivitySnapshotDelta?) -> bool
    def safe?(routes, version, delta)
      !unsafe_through_membership_event?(routes, version) &&
        !unsafe_nested_membership_delta?(routes, delta)
    end

    #: (untyped, untyped, RecordSnapshot, SnapshotNormalizer, Array[Array[untyped]], untyped, ActivitySnapshotDelta?) -> [bool, RecordSnapshot]
    def call( # rubocop:disable Metrics/ParameterLists
      root_endpoint,
      context_endpoint,
      previous,
      normalizer,
      routes,
      version,
      delta
    )
      fallback_record = [] #: Array[untyped]
      endpoints = [root_endpoint, context_endpoint]
      snapshot = routes.reduce(previous) do |current, route|
        apply_route(
          current, route, version, delta, fallback_record, normalizer, endpoints
        )
      end
      [true, snapshot]
    end

    private

    # @rbs @record_resolver: ActivityEventRecordResolver
    # @rbs @record_normalizer: ActivityEventRecordNormalizer
    # @rbs @route_updater: ActivityCollectionRouteUpdater
    # @rbs @relationship: ActivityRelationship

    #: (RecordSnapshot, Array[untyped], untyped, ActivitySnapshotDelta?, Array[untyped], SnapshotNormalizer, Array[untyped]) -> RecordSnapshot
    def apply_route( # rubocop:disable Metrics/ParameterLists
      snapshot, route, version, delta, fallback_record, normalizer, endpoints
    )
      record, replacement = route_event_state(
        snapshot, route, version, delta, fallback_record, normalizer, endpoints
      )
      change = ActivityCollectionRouteChange.new(
        route: route,
        version: version,
        record: record,
        replacement: replacement
      )
      @route_updater.call(snapshot, change).fetch(0)
    end

    #: (Array[Array[untyped]], untyped) -> bool
    def unsafe_through_membership_event?(routes, version)
      return false if version.event.to_s == 'update'

      routes.any? do |route|
        route.first(route.length - 1).any? do |entry|
          entry.fetch(1).options[:through]
        end
      end
    end

    #: (Array[Array[untyped]], ActivitySnapshotDelta?) -> bool
    def unsafe_nested_membership_delta?(routes, delta)
      return false unless delta

      routes.any? do |route|
        route.length > 1 && delta.relationship_changed?(route.last.fetch(1))
      end
    end

    #: (RecordSnapshot, Array[untyped], untyped, ActivitySnapshotDelta?, Array[untyped], SnapshotNormalizer, Array[untyped]) -> [untyped, RecordSnapshot?]
    def route_event_state( # rubocop:disable Metrics/ParameterLists
      snapshot, route, version, delta, fallback_record, normalizer, endpoints
    )
      existing = existing_delta_record(snapshot, route, version, delta) if delta
      return [delta, delta.apply(existing)] if delta && existing

      fallback_record << @record_resolver.record_after(version) if fallback_record.empty?
      record = fallback_record.first
      return [record, nil] unless record

      [record, normalized_event_record(record, route, normalizer, endpoints)]
    end

    #: (untyped, Array[untyped], SnapshotNormalizer, Array[untyped]) -> RecordSnapshot?
    def normalized_event_record(record, route, normalizer, endpoints)
      _name, reflection, subtree, path = route.last
      @record_normalizer.call(
        record,
        reflection: reflection,
        subtree: subtree,
        path: path,
        normalizer: normalizer,
        root_endpoint: endpoints.fetch(0),
        context_endpoint: endpoints.fetch(1)
      )
    end

    #: (RecordSnapshot, Array[untyped], untyped, ActivitySnapshotDelta?) -> RecordSnapshot?
    def existing_delta_record(snapshot, route, version, delta)
      return unless delta && route.length.between?(1, 2)

      owner = route.length == 1 ? snapshot : nested_delta_owner(snapshot, route, delta)
      return unless owner

      association = owner.associations.fetch(route.last.fetch(0))
      position = association.position_for_id(version.item_id)
      association.records.fetch(position) if position
    end

    #: (RecordSnapshot, Array[untyped], ActivitySnapshotDelta) -> RecordSnapshot?
    def nested_delta_owner(snapshot, route, delta)
      parent_name = route.first.fetch(0)
      reflection = route.last.fetch(1)
      association = snapshot.associations.fetch(parent_name)
      owner_id = @relationship.owner_id(delta, reflection, state: :before)
      position = association.position_for_id(owner_id)
      return unless position

      owner = association.records.fetch(position)
      owner if @relationship.member_of_owner?(delta, reflection, owner, state: :before)
    end
  end
end
