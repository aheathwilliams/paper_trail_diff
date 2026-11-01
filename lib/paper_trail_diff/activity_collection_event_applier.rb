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
      !scoped_route?(routes) &&
        !unsafe_through_membership_event?(routes, version) &&
        !unsafe_nested_membership_delta?(routes, delta) &&
        !unsafe_owned_relationship_delta?(routes, delta)
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
      direct = routes.all? { |route| route.last.fetch(2).empty? }
      snapshot = routes.reduce(previous) do |current, route|
        apply_route(
          current, route, version, delta, fallback_record, normalizer, endpoints, direct: direct
        )
      end
      [true, snapshot]
    end

    private

    # @rbs @record_resolver: ActivityEventRecordResolver
    # @rbs @record_normalizer: ActivityEventRecordNormalizer
    # @rbs @route_updater: ActivityCollectionRouteUpdater
    # @rbs @relationship: ActivityRelationship

    #: (RecordSnapshot, Array[untyped], untyped, ActivitySnapshotDelta?, Array[untyped], SnapshotNormalizer, Array[untyped], ?direct: bool) -> RecordSnapshot
    def apply_route( # rubocop:disable Metrics/ParameterLists
      snapshot, route, version, delta, fallback_record, normalizer, endpoints, direct: false
    )
      record, replacement = route_event_state(
        snapshot, route, version, delta, fallback_record, normalizer, endpoints, direct: direct
      )
      change = ActivityCollectionRouteChange.new(
        route: route,
        version: version,
        record: record,
        replacement: replacement
      )
      @route_updater.call(snapshot, change).fetch(0)
    end

    # Any edit can move a record into or out of a scope, so a scoped route's
    # branch is read again from history instead.
    #: (Array[Array[untyped]]) -> bool
    def scoped_route?(routes)
      routes.any? do |route|
        route.any? { |entry| ScopeCondition.scoped_path?(entry.fetch(1)) }
      end
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

    # A delta replaces a record's attributes and keeps its associations, so an
    # edit to a key one of them follows, such as a comment's `reviewer_id`
    # under `comments.reviewer`, would leave the old target in place. The
    # branch is read again instead.
    #: (Array[Array[untyped]], ActivitySnapshotDelta?) -> bool
    def unsafe_owned_relationship_delta?(routes, delta)
      return false unless delta

      routes.any? do |route|
        _name, reflection, subtree, = route.last
        subtree.children.each_key.any? do |name|
          owned_keys(reflection.klass.reflect_on_association(name)).any? do |key|
            delta.before_value(key).to_s != delta.after_value(key).to_s
          end
        end
      end
    end

    # The record's own columns that decide what an association of it holds: a
    # belongs_to's key and type, or those of the belongs_to a through starts
    # from. A has_one or has_many follows the record's primary key.
    #: (untyped) -> Array[untyped]
    def owned_keys(reflection)
      return [] unless reflection
      return owned_keys(reflection.through_reflection) if reflection.through_reflection?
      return [] unless reflection.belongs_to?

      keys = Array(reflection.foreign_key)
      reflection.polymorphic? ? [*keys, reflection.foreign_type] : keys
    end

    #: (RecordSnapshot, Array[untyped], untyped, ActivitySnapshotDelta?, Array[untyped], SnapshotNormalizer, Array[untyped], ?direct: bool) -> [untyped, RecordSnapshot?]
    def route_event_state( # rubocop:disable Metrics/ParameterLists
      snapshot, route, version, delta, fallback_record, normalizer, endpoints, direct: false
    )
      existing = existing_delta_record(snapshot, route, version, delta) if delta
      return [delta, delta.apply(existing)] if delta && existing

      if fallback_record.empty?
        fallback_record << @record_resolver.record_after(version, direct: direct)
      end
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
