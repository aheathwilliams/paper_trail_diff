# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Reuses immutable nodes whose normalized state did not change at a selected path.
  class SnapshotPool
    def initialize
      @records = {} #: Hash[Array[untyped], RecordSnapshot]
      @associations = {} #: Hash[String, AssociationSnapshot]
    end

    #: (String, RecordSnapshot) -> RecordSnapshot
    def record(path, snapshot)
      key = [path, snapshot.type, snapshot.id]
      previous = @records[key]
      return previous if previous && equivalent_record?(previous, snapshot)

      @records[key] = snapshot
    end

    #: (String, AssociationSnapshot) -> AssociationSnapshot
    def association(path, snapshot)
      previous = @associations[path]
      return previous if previous && same_association?(previous, snapshot)

      @associations[path] = snapshot
    end

    private

    # @rbs @records: Hash[Array[untyped], RecordSnapshot]
    # @rbs @associations: Hash[String, AssociationSnapshot]

    #: (RecordSnapshot, RecordSnapshot) -> bool
    def equivalent_record?(left, right)
      left.attributes == right.attributes &&
        left.associations.keys == right.associations.keys &&
        left.associations.all? do |name, association|
          same_association?(association, right.associations.fetch(name))
        end
    end

    #: (AssociationSnapshot, AssociationSnapshot) -> bool
    def same_association?(left, right)
      left.kind == right.kind && left.records == right.records
    end
  end

  # Converts an ActiveRecord graph into immutable, persistence-independent snapshots.
  class SnapshotNormalizer
    #: (tree: AssociationTree, ignore_policy: IgnorePolicy, traversal: AssociationTraversal, ?pool: SnapshotPool) -> void
    def initialize(tree:, ignore_policy:, traversal:, pool: SnapshotPool.new)
      @tree = tree
      @ignore_policy = ignore_policy
      @traversal = traversal
      @pool = pool
      @structural_columns = {} #: Hash[String, Array[String]]
      @excluded_attributes = {} #: Hash[Array[untyped], Array[String?]]
    end

    #: (untyped, reifier: untyped) -> RecordSnapshot?
    def call(record, reifier:)
      return unless record

      reflections = reflections_for(record, @tree, '')
      normalize_record(record, @tree, '', reifier, reflections)
    end

    # Normalizes one member of an already selected association branch.
    #: (untyped, tree: AssociationTree, path: String, incoming: untyped, reifier: untyped) -> RecordSnapshot?
    def call_child(record, tree:, path:, incoming:, reifier:)
      return unless record

      @structural_columns[path] ||= @traversal.incoming_relationship_columns(incoming)
      reflections = reflections_for(record, tree, path)
      reifier.reify(record, reflections) unless reflections.empty?
      normalize_record(record, tree, path, reifier, reflections)
    end

    # Normalizes scalar attributes without traversing or loading associations.
    #: (untyped, tree: AssociationTree, path: String) -> snapshot_attributes
    def attributes_for(record, tree:, path:)
      if record.instance_of?(PreparedRecordState)
        return from_state(record, tree: tree,
                                  path: path).attributes
      end

      reflections = reflections_for(record, tree, path)
      normalized_attributes(record, reflections, path)
    end

    # Same exclusions as AR normalization, applied to an already typed state.
    #: (PreparedRecordState, tree: AssociationTree, path: String, ?incoming: untyped, ?associations: snapshot_associations) -> RecordSnapshot
    def from_state(state, tree:, path:, incoming: nil, associations: {})
      model = state.model_class
      @structural_columns[path] ||= @traversal.incoming_relationship_columns(incoming) if incoming
      reflections = @traversal.reflections_for(model, tree, path: path)
      excluded = @excluded_attributes[[model, path]] ||=
        build_excluded_attributes(model, reflections, path)
      snapshot = RecordSnapshot.new(
        type: model.name, id: state_id(model, state),
        attributes: state.attributes.except(*excluded), associations: associations
      )
      pool_state(path, snapshot)
    end

    private

    # The id a live record of the same row reports: one value, or one per
    # column of a composite key.
    #: (untyped, PreparedRecordState) -> untyped
    def state_id(model, state)
      key = model.primary_key
      key.instance_of?(Array) ? state.attributes.fetch_values(*key) : state.attributes.fetch(key)
    end

    #: (String, RecordSnapshot) -> RecordSnapshot
    def pool_state(path, snapshot)
      path.empty? ? snapshot : @pool.record(path, snapshot)
    end

    # @rbs @tree: AssociationTree
    # @rbs @ignore_policy: IgnorePolicy
    # @rbs @traversal: AssociationTraversal
    # @rbs @pool: SnapshotPool
    # @rbs @structural_columns: Hash[String, Array[String]]
    # @rbs @excluded_attributes: Hash[Array[untyped], Array[String?]]

    #: (untyped, AssociationTree, String, untyped, Array[untyped]) -> RecordSnapshot
    def normalize_record(record, tree, path, reifier, reflections)
      snapshot = RecordSnapshot.new(
        type: record.class.name,
        id: record.id,
        attributes: normalized_attributes(record, reflections, path),
        associations: normalize_associations(record, tree, path, reifier, reflections)
      )
      path.empty? ? snapshot : @pool.record(path, snapshot)
    end

    #: (untyped, Array[untyped], String) -> snapshot_attributes
    def normalized_attributes(record, reflections, path)
      attributes = record.attributes
      excluded_attributes(record, reflections, path).each { |name| attributes.delete(name) }
      StoredTimePrecision.apply(attributes, StoredTimePrecision.digits(record.class))
    end

    # Every input is fixed for one model class at one selected path, and the
    # path's structural columns are recorded before its records normalize, so
    # this is resolved once instead of per record per boundary.
    #: (untyped, Array[untyped], String) -> Array[String?]
    def excluded_attributes(record, reflections, path)
      model_class = record.class
      @excluded_attributes[[model_class, path]] ||=
        build_excluded_attributes(model_class, reflections, path)
    end

    #: (untyped, Array[untyped], String) -> Array[String?]
    def build_excluded_attributes(model_class, reflections, path)
      primary_keys = Array(model_class.primary_key) #: Array[String]
      ignored = @ignore_policy.attributes_for(path)
      structural = @structural_columns.fetch(path, [])
      primary_keys + ignored + skipped_columns(model_class) +
        relationship_columns(reflections) + structural
    end

    # `has_paper_trail skip:` columns are never written to a version, so history
    # holds only their defaults. Compared with a live row they would report a
    # change nobody recorded.
    #: (untyped) -> Array[String]
    def skipped_columns(model_class)
      return [] unless Support.versioned?(model_class)

      # PaperTrail stores these as strings, or hashes keyed by strings.
      entries = model_class.paper_trail_options.fetch(:skip) #: Array[untyped]
      entries.flat_map { |entry| entry.instance_of?(Hash) ? entry.keys : entry }
    end

    # A non-polymorphic reflection has no foreign type, so it adds nil, which
    # excludes nothing.
    #: (Array[untyped]) -> Array[String?]
    def relationship_columns(reflections)
      reflections.select { |reflection| reflection.macro == :belongs_to }.flat_map do |reflection|
        [reflection.foreign_key, reflection.foreign_type]
      end
    end

    #: (untyped, AssociationTree, String, untyped, Array[untyped]) -> Hash[String, AssociationSnapshot]
    def normalize_associations(record, tree, path, reifier, reflections)
      reflections.to_h do |reflection|
        name = reflection.name.to_s
        [name, association_snapshot(record, reflection, tree.children.fetch(name), path, reifier)]
      end
    end

    #: (untyped, untyped, AssociationTree, String, untyped) -> AssociationSnapshot
    def association_snapshot(
      record,
      reflection,
      subtree,
      path,
      reifier
    )
      # A reified history can hold a member PaperTrail could not rebuild.
      records = Array(record.public_send(reflection.name)).compact
      child_path = Support.association_path(path, reflection.name)
      @structural_columns[child_path] ||= @traversal.incoming_relationship_columns(reflection)
      snapshot = AssociationSnapshot.new(
        kind: reflection.macro,
        records: normalize_children(records, subtree, child_path, reifier)
      )
      @pool.association(child_path, snapshot)
    end

    #: (Array[untyped], AssociationTree, String, untyped) -> Array[RecordSnapshot]
    def normalize_children(records, tree, path, reifier)
      reflections_by_class = {} #: Hash[untyped, Array[untyped]]
      records.map do |child|
        reflections = reflections_by_class[child.class] ||= reflections_for(child, tree, path)
        reifier.reify(child, reflections) unless reflections.empty?
        normalize_record(child, tree, path, reifier, reflections)
      end
    end

    #: (untyped, AssociationTree, String) -> Array[untyped]
    def reflections_for(record, tree, path)
      @traversal.reflections_for(record.class, tree, path: path)
    end
  end
end
