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
      if previous && previous.kind == snapshot.kind && previous.records == snapshot.records
        return previous
      end

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
          other = right.associations[name]
          other && association.kind == other.kind && association.records == other.records
        end
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
      @excluded_attributes = {} #: Hash[Array[untyped], Array[String]]
    end

    #: (untyped, reifier: untyped) -> RecordSnapshot?
    def call(record, reifier:)
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
      reflections = reflections_for(record, tree, path)
      normalized_attributes(record, reflections, path)
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @ignore_policy: IgnorePolicy
    # @rbs @traversal: AssociationTraversal
    # @rbs @pool: SnapshotPool
    # @rbs @structural_columns: Hash[String, Array[String]]
    # @rbs @excluded_attributes: Hash[Array[untyped], Array[String]]

    #: (untyped, AssociationTree, String, untyped, Array[untyped]) -> RecordSnapshot?
    def normalize_record(record, tree, path, reifier, reflections)
      return unless record

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
      attributes = record.attributes.dup
      excluded_attributes(record, reflections, path).each { |name| attributes.delete(name) }
      attributes
    end

    # Every input is fixed for one model class at one selected path, and the
    # path's structural columns are recorded before its records normalize, so
    # this is resolved once instead of per record per boundary.
    #: (untyped, Array[untyped], String) -> Array[String]
    def excluded_attributes(record, reflections, path)
      model_class = record.class
      @excluded_attributes[[model_class, path]] ||=
        build_excluded_attributes(model_class, reflections, path)
    end

    #: (untyped, Array[untyped], String) -> Array[String]
    def build_excluded_attributes(model_class, reflections, path)
      primary_key = model_class.primary_key #: untyped
      primary_keys = primary_key.is_a?(Array) ? primary_key : [primary_key]
      # @type var primary_keys: Array[untyped]
      primary_keys = primary_keys.map { |key| key.to_s } # rubocop:disable Style/SymbolProc
      ignored = @ignore_policy.attributes_for(path)
      structural = @structural_columns.fetch(path, [])
      (primary_keys + ignored + relationship_columns(reflections) + structural).uniq.freeze
    end

    #: (Array[untyped]) -> Array[String]
    def relationship_columns(reflections)
      reflections.select { |reflection| reflection.macro == :belongs_to }.flat_map do |reflection|
        columns = [reflection.foreign_key.to_s]
        columns << reflection.foreign_type.to_s if reflection.polymorphic?
        columns
      end
    end

    #: (untyped, AssociationTree, String, untyped, Array[untyped]) -> Hash[String, AssociationSnapshot]
    def normalize_associations(record, tree, path, reifier, reflections)
      reflections.to_h do |reflection|
        name = reflection.name.to_s
        subtree = tree.child(name)
        raise ConfigurationError, "missing traversal subtree: #{name}" unless subtree

        [name, association_snapshot(record, reflection, subtree, path, reifier)]
      end
    end

    #: (untyped, untyped, AssociationTree, String, untyped) -> AssociationSnapshot
    def association_snapshot( # rubocop:disable Metrics/AbcSize
      record,
      reflection,
      subtree,
      path,
      reifier
    )
      associated = record.public_send(reflection.name)
      records = if AssociationSnapshot.collection_kind?(reflection.macro)
                  associated.to_a
                else
                  Array(associated).compact
                end
      child_path = Support.association_path(path, reflection.name.to_s)
      @structural_columns[child_path] ||= @traversal.incoming_relationship_columns(reflection)
      snapshot = AssociationSnapshot.new(
        kind: reflection.macro,
        records: normalize_children(records, subtree, child_path, reifier)
      )
      @pool.association(child_path, snapshot)
    end

    #: (Array[untyped], AssociationTree, String, untyped) -> Array[RecordSnapshot]
    def normalize_children(records, tree, path, reifier)
      reflections_by_class = {} #: Hash[String, Array[untyped]]
      records.filter_map do |child|
        type = child.class.name
        reflections = reflections_by_class[type] ||= reflections_for(child, tree, path)
        reifier.reify(child, reflections) unless reflections.empty?
        normalize_record(child, tree, path, reifier, reflections)
      end
    end

    #: (untyped, AssociationTree, String) -> Array[untyped]
    def reflections_for(record, tree, path)
      return [] unless record

      @traversal.reflections_for(record.class, tree, path: path)
    end
  end
end
