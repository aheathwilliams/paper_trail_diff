# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Applies selected non-polymorphic belongs-to target updates to a snapshot.
  class ActivityBelongsToEventApplier
    #: (route_finder: ActivityEventRouteFinder, record_resolver: ActivityEventRecordResolver, record_normalizer: ActivityEventRecordNormalizer) -> void
    def initialize(route_finder:, record_resolver:, record_normalizer:)
      @route_finder = route_finder
      @record_resolver = record_resolver
      @record_normalizer = record_normalizer
    end

    #: (untyped, untyped, RecordSnapshot, AssociationTree, SnapshotNormalizer, untyped) -> [bool, RecordSnapshot?]
    def call( # rubocop:disable Metrics/ParameterLists
      root_endpoint,
      context_endpoint,
      previous,
      tree,
      normalizer,
      version
    )
      return [false, nil] unless %w[update destroy].include?(version.event.to_s)

      routes = @route_finder.belongs_to_routes(
        endpoint_model_class(root_endpoint), tree, version.item_type.to_s
      )
      return [false, nil] if routes.empty?

      snapshot = previous
      routes.each do |route|
        replacement = normalized_route_record(
          route, version, normalizer, root_endpoint, context_endpoint
        )
        snapshot, = replace_route(snapshot, route, version, replacement)
      end
      [true, snapshot]
    end

    private

    # @rbs @route_finder: ActivityEventRouteFinder
    # @rbs @record_resolver: ActivityEventRecordResolver
    # @rbs @record_normalizer: ActivityEventRecordNormalizer

    #: (Array[untyped], untyped, SnapshotNormalizer, untyped, untyped) -> RecordSnapshot?
    def normalized_route_record(route, version, normalizer, root_endpoint, context_endpoint)
      record = @record_resolver.record_after(version)
      return unless record

      _name, reflection, subtree, path = route.last
      @record_normalizer.call(
        record,
        reflection: reflection,
        subtree: subtree,
        path: path,
        normalizer: normalizer,
        root_endpoint: root_endpoint,
        context_endpoint: context_endpoint
      )
    end

    #: (RecordSnapshot, Array[untyped], untyped, RecordSnapshot?, ?depth: Integer) -> [RecordSnapshot, bool]
    def replace_route(snapshot, route, version, replacement, depth: 0)
      name, _reflection, _subtree, = route.fetch(depth)
      association = snapshot.associations.fetch(name)
      records, changed = replacement_records(
        association.records, route, version, replacement, depth
      )
      return [snapshot, false] unless changed

      updated_association = AssociationSnapshot.new(kind: association.kind, records: records)
      [replace_association(snapshot, name, updated_association), true]
    end

    #: (Array[RecordSnapshot], Array[untyped], untyped, RecordSnapshot?, Integer) -> [Array[RecordSnapshot], bool]
    def replacement_records(records, route, version, replacement, depth)
      return replace_existing_target(records, version, replacement) if depth == route.length - 1

      changed = false
      updated = records.map do |record|
        result, record_changed = replace_route(
          record, route, version, replacement, depth: depth + 1
        )
        changed ||= record_changed
        result
      end.freeze
      [updated, changed]
    end

    #: (Array[RecordSnapshot], untyped, RecordSnapshot?) -> [Array[RecordSnapshot], bool]
    def replace_existing_target(records, version, replacement)
      index = records.index do |record|
        record.id.to_s == version.item_id.to_s &&
          record.type.to_s == replacement_type(version, replacement)
      end
      return [records, false] unless index

      updated = records.dup
      replacement ? updated[index] = replacement : updated.delete_at(index)
      [updated.freeze, true]
    end

    #: (RecordSnapshot, String, AssociationSnapshot) -> RecordSnapshot
    def replace_association(snapshot, name, association)
      RecordSnapshot.new(
        type: snapshot.type,
        id: snapshot.id,
        attributes: snapshot.attributes,
        associations: snapshot.associations.merge(name => association)
      )
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
end
