# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Applies selected non-polymorphic belongs-to target updates to a snapshot.
  # A target created there changes nothing unless an owner already named it,
  # as one can where no foreign key constraint forbids it (see #created).
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
      event = version.event.to_s
      return [false, nil] unless %w[create update destroy].include?(event)

      routes = @route_finder.belongs_to_routes(
        RecordedClass.of_endpoint(root_endpoint), tree, version.item_type.to_s
      )
      return [false, nil] if routes.empty? || ActivityEventRouteFinder.scoped_route?(routes)
      return created(previous, routes) if event == 'create'

      snapshot = previous
      routes.each do |route|
        replacement = normalized_route_record(route, version, normalizer, context_endpoint)
        snapshot, = replace_route(snapshot, route, version, replacement)
      end
      [true, snapshot]
    end

    private

    # @rbs @route_finder: ActivityEventRouteFinder
    # @rbs @record_resolver: ActivityEventRecordResolver
    # @rbs @record_normalizer: ActivityEventRecordNormalizer

    # A created target is new to the snapshot unless an owner named it first.
    # A snapshot leaves out an owner's key, but an owner that names a record
    # holds one, and only an owner holding none can name a record that does
    # not exist yet: the branch is read again only when there is such an
    # owner.
    #: (RecordSnapshot, Array[Array[untyped]]) -> [bool, RecordSnapshot?]
    def created(previous, routes)
      vacant = routes.any? { |route| vacant?(previous, route, 0) }
      vacant ? [false, nil] : [true, previous]
    end

    # Whether a record along the route holds no target where it ends, or the
    # snapshot does not say.
    #: (RecordSnapshot, Array[untyped], Integer) -> bool
    def vacant?(snapshot, route, depth)
      association = snapshot.associations[route.fetch(depth).fetch(0)]
      return true unless association
      return association.records.empty? if depth == route.length - 1

      association.records.any? { |record| vacant?(record, route, depth + 1) }
    end

    #: (Array[untyped], untyped, SnapshotNormalizer, untyped) -> RecordSnapshot?
    def normalized_route_record(route, version, normalizer, context_endpoint)
      record = @record_resolver.record_after(version, direct: route.last.fetch(2).empty?)
      return unless record

      _name, reflection, subtree, path = route.last
      @record_normalizer.call(
        record,
        reflection: reflection,
        subtree: subtree,
        path: path,
        normalizer: normalizer,
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
      [snapshot.with_association(name, updated_association), true]
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
        record.id.to_s == version.item_id.to_s && same_table?(record, version)
      end
      return [records, false] unless index

      updated = records.dup
      replacement ? updated[index] = replacement : updated.delete_at(index)
      [updated.freeze, true]
    end

    # The target is matched by id within its table rather than by type name.
    # Without `item_subtype`, a version names only the STI base class, and a
    # row whose type changes is replaced by a record of another class.
    #: (RecordSnapshot, untyped) -> bool
    def same_table?(record, version)
      model = AssociationTraversal.named_class(record.type.to_s)
      !model.nil? && model.base_class == Endpoint.model_class(version).base_class
    end
  end
end
