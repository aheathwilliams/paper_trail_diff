# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Applies safe descendant event deltas without rebuilding an entire selected branch.
  # rubocop:disable Metrics/ClassLength
  class ActivityEventSnapshotRefresher
    #: (traversal: AssociationTraversal, pool: SnapshotPool, components: untyped, ?association_reader: untyped, ?record_transition: untyped) -> void
    def initialize(traversal:, pool:, components:, association_reader: nil, record_transition: nil)
      @traversal = traversal
      @pool = pool
      @components = components
      @association_reader = association_reader || method(:historical_reader)
      @record_resolver = ActivityEventRecordResolver.new(record_transition: record_transition)
      @route_finder = ActivityEventRouteFinder.new(traversal)
      @relationship = ActivityRelationship.new
    end

    #: (untyped, untyped, RecordSnapshot, Array[String], ActivityEvent?) -> [bool, RecordSnapshot?]
    def call( # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      root_endpoint,
      context_endpoint,
      previous,
      branches,
      event
    )
      return [false, nil] unless event && branches.one?

      tree, normalizer = @components.call(branches)
      collection_routes = direct_collection_routes(
        endpoint_model_class(root_endpoint),
        tree,
        event.version.item_type.to_s
      )
      unless collection_routes.empty?
        return [false, nil] if unsafe_through_membership_event?(collection_routes, event.version)

        delta = activity_snapshot_delta(event.version)
        return [false, nil] if unsafe_nested_membership_delta?(collection_routes, delta)

        return collection_target_snapshot(
          root_endpoint,
          context_endpoint,
          previous,
          normalizer,
          collection_routes,
          event.version,
          delta
        )
      end

      belongs_to_target_snapshot(
        root_endpoint,
        context_endpoint,
        previous,
        tree,
        normalizer,
        event.version
      )
    end

    private

    # @rbs @traversal: AssociationTraversal
    # @rbs @pool: SnapshotPool
    # @rbs @components: untyped
    # @rbs @association_reader: untyped
    # @rbs @record_resolver: ActivityEventRecordResolver
    # @rbs @route_finder: ActivityEventRouteFinder
    # @rbs @relationship: ActivityRelationship

    #: (Array[Array[untyped]], untyped) -> bool
    def unsafe_through_membership_event?(routes, version)
      return false if version.event.to_s == 'update'

      routes.any? do |route|
        route.first(route.length - 1).any? do |entry|
          reflection = entry.fetch(1)
          reflection.options[:through]
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

    #: (untyped, untyped, RecordSnapshot, SnapshotNormalizer, Array[Array[untyped]], untyped, ActivitySnapshotDelta?) -> [bool, RecordSnapshot]
    def collection_target_snapshot( # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
      root_endpoint,
      context_endpoint,
      previous,
      normalizer,
      routes,
      version,
      delta
    )
      fallback_record = [] #: Array[untyped]
      snapshot = previous
      routes.each do |route|
        record, replacement = collection_route_event_state(
          snapshot,
          route,
          version,
          delta,
          fallback_record,
          normalizer,
          root_endpoint,
          context_endpoint
        )
        snapshot, = replace_collection_route(snapshot, route, version, record, replacement)
      end
      [true, snapshot]
    end

    #: (RecordSnapshot, Array[untyped], untyped, ActivitySnapshotDelta?, Array[untyped], SnapshotNormalizer, untyped, untyped) -> [untyped, RecordSnapshot?]
    def collection_route_event_state( # rubocop:disable Metrics/ParameterLists
      snapshot,
      route,
      version,
      delta,
      fallback_record,
      normalizer,
      root_endpoint,
      context_endpoint
    )
      existing = existing_delta_record(snapshot, route, version, delta) if delta
      return [delta, delta.apply(existing)] if delta && existing

      fallback_record << record_after(version) if fallback_record.empty?
      record = fallback_record.first
      return [record, nil] unless record

      [record, normalized_collection_event_record(
        record, route, normalizer, root_endpoint, context_endpoint
      )]
    end

    #: (untyped, Array[untyped], SnapshotNormalizer, untyped, untyped) -> RecordSnapshot?
    def normalized_collection_event_record(
      record,
      route,
      normalizer,
      root_endpoint,
      context_endpoint
    )
      _name, reflection, subtree, path = route.last
      normalize_event_record(
        record,
        reflection,
        subtree,
        path,
        normalizer,
        root_endpoint,
        context_endpoint
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
      owner_id = relationship_owner_id(delta, reflection, state: :before)
      position = association.position_for_id(owner_id)
      return unless position

      owner = association.records.fetch(position)
      owner if member_of_owner?(delta, reflection, owner, state: :before)
    end

    #: (untyped, AssociationTree, String, ?path: String) -> Array[Array[untyped]]
    def direct_collection_routes(model_class, tree, target_type, path: '')
      @route_finder.collection_routes(model_class, tree, target_type, path: path)
    end

    #: (RecordSnapshot, Array[untyped], untyped, untyped, RecordSnapshot?, ?depth: Integer) -> [RecordSnapshot, bool]
    def replace_collection_route( # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
      snapshot,
      route,
      version,
      record,
      replacement,
      depth: 0
    )
      name, reflection, _subtree, path = route.fetch(depth)
      association = snapshot.associations.fetch(name)
      changed = false
      transition_before = nil #: RecordSnapshot?
      transition_after = nil #: RecordSnapshot?
      membership_preserved = true
      updated_records = if depth == route.length - 1
                          child = collection_event_child(
                            association,
                            version,
                            record,
                            reflection,
                            snapshot,
                            replacement
                          )
                          records, transition_before, transition_after, membership_preserved =
                            replace_collection_record(association, version, child)
                          records.tap { |value| changed = !value.equal?(association.records) }
                        elsif (targeted = replace_targeted_collection_parent(
                          association,
                          route,
                          version,
                          record,
                          replacement,
                          depth
                        ))
                          records, transition_before, transition_after, changed = targeted
                          records
                        else
                          association.records.map do |child_snapshot|
                            updated, child_changed = replace_collection_route(
                              child_snapshot,
                              route,
                              version,
                              record,
                              replacement,
                              depth: depth + 1
                            )
                            if child_changed
                              transition_before = nil if changed
                              transition_after = nil if changed
                              unless changed
                                transition_before = child_snapshot
                                transition_after = updated
                              end
                              changed = true
                            end
                            updated
                          end.freeze
                        end
      return [snapshot, false] unless changed

      updated_association = @pool.association(
        path,
        association.transition_to(
          updated_records,
          before: transition_before,
          after: transition_after,
          membership_preserved: membership_preserved
        )
      )
      updated_snapshot = RecordSnapshot.new(
        type: snapshot.type,
        id: snapshot.id,
        attributes: snapshot.attributes,
        associations: snapshot.associations.merge(name => updated_association)
      )
      parent_path = depth.zero? ? '' : route.fetch(depth - 1).fetch(3)
      updated_snapshot = @pool.record(parent_path, updated_snapshot) unless parent_path.empty?
      [updated_snapshot, true]
    end

    #: (AssociationSnapshot, untyped, untyped, untyped, RecordSnapshot, RecordSnapshot?) -> RecordSnapshot?
    def collection_event_child( # rubocop:disable Metrics/ParameterLists
      association, version, record, reflection, owner, replacement
    )
      return unless record

      unless record.is_a?(ActivitySnapshotDelta)
        return replacement if member_of_owner?(record, reflection, owner)

        return
      end
      unless record.relationship_changed?(reflection)
        return replacement if association.position_for_id(version.item_id)

        return
      end

      replacement if member_of_owner?(record, reflection, owner)
    end

    #: (AssociationSnapshot, Array[untyped], untyped, untyped, RecordSnapshot?, Integer) -> [Array[RecordSnapshot], RecordSnapshot?, RecordSnapshot?, bool]?
    def replace_targeted_collection_parent( # rubocop:disable Metrics/ParameterLists
      association,
      route,
      version,
      record,
      replacement,
      depth
    )
      return unless depth == route.length - 2

      reflection = route.fetch(depth + 1).fetch(1)
      position = nested_owner_position(association, reflection, version, record)
      return unless position

      before = association.records.fetch(position)
      after, changed = replace_collection_route(
        before,
        route,
        version,
        record,
        replacement,
        depth: depth + 1
      )
      targeted_parent_replacement(association.records, position, before, after, changed)
    end

    #: (Array[RecordSnapshot], Integer, RecordSnapshot, RecordSnapshot, bool) -> [Array[RecordSnapshot], RecordSnapshot?, RecordSnapshot?, bool]
    def targeted_parent_replacement(records, position, before, after, changed)
      return [records, nil, nil, false] unless changed

      updated = records.dup
      updated[position] = after
      [updated.freeze, before, after, true]
    end

    #: (AssociationSnapshot, untyped, untyped, untyped) -> Integer?
    def nested_owner_position(association, reflection, version, record)
      membership_record = record || version.reify(dup: true)
      return unless membership_record
      return if membership_record.is_a?(ActivitySnapshotDelta) &&
                membership_record.relationship_changed?(reflection)

      owner_id = relationship_owner_id(membership_record, reflection, state: :after)
      association.position_for_id(owner_id)
    end

    #: (untyped, untyped, RecordSnapshot, AssociationTree, SnapshotNormalizer, untyped) -> [bool, RecordSnapshot?]
    def belongs_to_target_snapshot( # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists
      root_endpoint,
      context_endpoint,
      previous,
      tree,
      normalizer,
      version
    )
      return [false, nil] unless %w[update destroy].include?(version.event.to_s)

      root_class = endpoint_model_class(root_endpoint)
      routes = belongs_to_routes(root_class, tree, version.item_type.to_s)
      return [false, nil] if routes.empty?

      snapshot = previous
      routes.each do |route|
        replacement = normalized_route_record(
          route,
          version,
          normalizer,
          root_endpoint,
          context_endpoint
        )
        snapshot, = replace_route(snapshot, route, version, replacement)
      end
      [true, snapshot]
    end

    #: (untyped, AssociationTree, String, ?path: String) -> Array[Array[untyped]]
    def belongs_to_routes(model_class, tree, target_type, path: '')
      @route_finder.belongs_to_routes(model_class, tree, target_type, path: path)
    end

    #: (Array[untyped], untyped, SnapshotNormalizer, untyped, untyped) -> RecordSnapshot?
    def normalized_route_record(route, version, normalizer, root_endpoint, context_endpoint)
      record = record_after(version)
      return unless record

      _name, reflection, subtree, path = route.last
      normalize_event_record(
        record,
        reflection,
        subtree,
        path,
        normalizer,
        root_endpoint,
        context_endpoint
      )
    end

    #: (RecordSnapshot, Array[untyped], untyped, RecordSnapshot?, ?depth: Integer) -> [RecordSnapshot, bool]
    def replace_route( # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      snapshot,
      route,
      version,
      replacement,
      depth: 0
    )
      name, _reflection, _subtree, = route.fetch(depth)
      association = snapshot.associations.fetch(name)

      records = association.records
      changed = false
      updated_records = if depth == route.length - 1
                          replace_existing_target(records, version, replacement).tap do |value|
                            changed = !value.equal?(records)
                          end
                        else
                          records.map do |record|
                            updated, record_changed = replace_route(
                              record,
                              route,
                              version,
                              replacement,
                              depth: depth + 1
                            )
                            changed ||= record_changed
                            updated
                          end.freeze
                        end
      return [snapshot, false] unless changed

      updated_association = AssociationSnapshot.new(
        kind: association.kind,
        records: updated_records
      )
      updated_snapshot = RecordSnapshot.new(
        type: snapshot.type,
        id: snapshot.id,
        attributes: snapshot.attributes,
        associations: snapshot.associations.merge(name => updated_association)
      )
      [updated_snapshot, true]
    end

    #: (Array[RecordSnapshot], untyped, RecordSnapshot?) -> Array[RecordSnapshot]
    def replace_existing_target(records, version, replacement)
      index = records.index do |record|
        record.id.to_s == version.item_id.to_s &&
          record.type.to_s == replacement_type(version, replacement)
      end
      return records unless index

      updated = records.dup
      replacement ? updated[index] = replacement : updated.delete_at(index)
      updated.freeze
    end

    #: (untyped) -> untyped
    def record_after(version)
      @record_resolver.record_after(version)
    end

    # PaperTrail create/update versions contain deserialized change pairs, so
    # their post-event records need no successor query.
    #: (untyped) -> untyped
    def changed_record_after(version)
      @record_resolver.changed_record_after(version)
    end

    #: (untyped) -> untyped
    def created_record_after(version)
      @record_resolver.created_record_after(version)
    end

    #: (untyped) -> untyped
    def updated_record_after(version)
      @record_resolver.updated_record_after(version)
    end

    # Mirrors PaperTrail's changeset deserialization without resolving
    # +version.item+, which would issue one live-record query per event.
    #: (untyped, untyped) -> untyped
    def deserialized_changeset(version, model_class)
      @record_resolver.deserialized_changeset(version, model_class)
    end

    #: (untyped) -> ActivitySnapshotDelta?
    def activity_snapshot_delta(version)
      @record_resolver.snapshot_delta(version)
    end

    #: (untyped, untyped, RecordSnapshot, ?state: Symbol) -> bool
    def member_of_owner?(record, reflection, owner, state: :after)
      @relationship.member_of_owner?(record, reflection, owner, state: state)
    end

    #: (untyped, untyped, state: Symbol) -> untyped
    def relationship_owner_id(record, reflection, state:)
      @relationship.owner_id(record, reflection, state: state)
    end

    #: (untyped, untyped, AssociationTree, String, SnapshotNormalizer, untyped, untyped) -> RecordSnapshot?
    def normalize_event_record( # rubocop:disable Metrics/ParameterLists
      record,
      reflection,
      subtree,
      path,
      normalizer,
      root_endpoint,
      context_endpoint
    )
      habtm_boundary = Endpoint.version?(root_endpoint) ? root_endpoint : context_endpoint
      reifier = @association_reader.call(
        context_endpoint,
        habtm_version: habtm_boundary
      )
      normalizer.call_child(
        record,
        tree: subtree,
        path: path,
        incoming: reflection,
        reifier: reifier
      )
    end

    #: (untyped, habtm_version: untyped) -> HistoricalAssociationReifier
    def historical_reader(context_endpoint, habtm_version:)
      HistoricalAssociationReifier.new(context_endpoint, habtm_version: habtm_version)
    end

    #: (AssociationSnapshot, untyped, RecordSnapshot?) -> [Array[RecordSnapshot], RecordSnapshot?, RecordSnapshot?, bool]
    def replace_collection_record(association, version, replacement)
      records = association.records
      position = association.position(
        replacement_type(version, replacement),
        version.item_id
      )
      return [records, nil, nil, true] unless replacement || position

      before = records.fetch(position) if position
      updated = replacement_collection_records(records, position, replacement)
      [updated, before, replacement, !before.nil? && !replacement.nil?]
    end

    #: (Array[RecordSnapshot], Integer?, RecordSnapshot?) -> Array[RecordSnapshot]
    def replacement_collection_records(records, position, replacement)
      updated = records.dup
      if replacement
        position ? updated[position] = replacement : updated << replacement
      else
        position ||= raise(ConfigurationError, 'missing collection event identity')
        updated.delete_at(position)
      end
      updated.freeze
    end

    #: (untyped, RecordSnapshot?) -> String
    def replacement_type(version, replacement)
      return replacement.type.to_s if replacement

      Endpoint.model_class(version).name.to_s
    end

    #: (untyped) -> untyped
    def endpoint_model_class(endpoint)
      Endpoint.version?(endpoint) ? Endpoint.model_class(endpoint) : endpoint.class
    end
  end
  # rubocop:enable Metrics/ClassLength
end
