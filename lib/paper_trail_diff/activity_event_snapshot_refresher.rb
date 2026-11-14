# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Dispatches safe descendant events to focused immutable snapshot appliers.
  class ActivityEventSnapshotRefresher
    #: (traversal: AssociationTraversal, pool: SnapshotPool, components: untyped, association_reader: untyped, ?record_transition: untyped, ?prepared_record_after: untyped) -> void
    def initialize(traversal:, pool:, components:, association_reader:, record_transition: nil, prepared_record_after: nil) # rubocop:disable Layout/LineLength, Metrics/ParameterLists
      @components = components
      @record_resolver = ActivityEventRecordResolver.new(
        record_transition: record_transition, prepared_record_after: prepared_record_after
      )
      @route_finder = ActivityEventRouteFinder.new(traversal)
      @places = ActivityTreePlaces.new(traversal)
      @relationship = ActivityRelationship.new
      configure_appliers(pool, association_reader)
    end

    #: (SnapshotPool, untyped) -> void
    def configure_appliers(pool, association_reader)
      route_updater = collection_updater(pool)
      record_normalizer = ActivityEventRecordNormalizer.new(
        association_reader: association_reader
      )
      @collection_applier = collection_applier(record_normalizer, route_updater)
      @belongs_to_applier = belongs_to_applier(record_normalizer)
    end

    #: (SnapshotPool) -> ActivityCollectionRouteUpdater
    def collection_updater(pool)
      ActivityCollectionRouteUpdater.new(pool: pool, relationship: @relationship)
    end

    #: (ActivityEventRecordNormalizer, ActivityCollectionRouteUpdater) -> ActivityCollectionEventApplier
    def collection_applier(record_normalizer, route_updater)
      ActivityCollectionEventApplier.new(
        record_resolver: @record_resolver,
        record_normalizer: record_normalizer,
        route_updater: route_updater,
        relationship: @relationship
      )
    end

    #: (ActivityEventRecordNormalizer) -> ActivityBelongsToEventApplier
    def belongs_to_applier(record_normalizer)
      ActivityBelongsToEventApplier.new(
        route_finder: @route_finder,
        record_resolver: @record_resolver,
        record_normalizer: record_normalizer
      )
    end

    # Nothing is applied for a record with places of two kinds in the tree,
    # since an event is applied at those of one kind only (see
    # ActivityTreePlaces).
    #: (untyped, untyped, RecordSnapshot, Array[String], ActivityEvent?) -> [bool, RecordSnapshot?]
    def call(root_endpoint, context_endpoint, previous, branches, event)
      return [false, nil] unless event && branches.one?

      root_class = RecordedClass.of_endpoint(root_endpoint)
      return [false, nil] unless @places.one_kind?(root_class, event.version.item_type.to_s)

      apply(root_class, [root_endpoint, context_endpoint], previous, branches, event)
    end

    private

    #: (untyped, Array[untyped], RecordSnapshot, Array[String], ActivityEvent) -> [bool, RecordSnapshot?]
    def apply(root_class, endpoints, previous, branches, event)
      root_endpoint, context_endpoint = endpoints
      tree, normalizer = @components.call(branches)
      routes = @route_finder.collection_routes(root_class, tree, event.version.item_type.to_s)
      unless routes.empty?
        delta = @record_resolver.snapshot_delta(event.version)
        return [false, nil] unless collection_safe?(root_endpoint, tree, routes, event, delta)

        return @collection_applier.call(
          root_endpoint, context_endpoint, previous, normalizer, routes, event.version, delta
        )
      end

      @belongs_to_applier.call(
        root_endpoint, context_endpoint, previous, tree, normalizer, event.version
      )
    end

    # @rbs @places: ActivityTreePlaces
    # @rbs @components: untyped
    # @rbs @record_resolver: ActivityEventRecordResolver
    # @rbs @route_finder: ActivityEventRouteFinder
    # @rbs @relationship: ActivityRelationship
    # @rbs @collection_applier: ActivityCollectionEventApplier
    # @rbs @belongs_to_applier: ActivityBelongsToEventApplier

    private :belongs_to_applier, :collection_applier, :collection_updater, :configure_appliers

    # A through's membership follows the keys of the records it joins through
    # or reaches, which a route to such a record elsewhere in the tree leaves
    # alone, so the branch is read again instead.
    #: (untyped, AssociationTree, Array[Array[untyped]], ActivityEvent, ActivitySnapshotDelta?) -> bool
    def collection_safe?(root_endpoint, tree, routes, event, delta)
      version = event.version
      !@route_finder.through_part?(RecordedClass.of_endpoint(root_endpoint), tree,
                                   version.item_type.to_s) &&
        @collection_applier.safe?(routes, version, delta)
    end

    #: (untyped) -> untyped
    def record_after(version)
      @record_resolver.record_after(version, direct: true)
    end

    #: (untyped, untyped) -> untyped
    def deserialized_changeset(version, model_class)
      @record_resolver.deserialized_changeset(version, model_class)
    end
  end
end
