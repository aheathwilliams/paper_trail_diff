# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Converts an ActiveRecord graph into immutable, persistence-independent snapshots.
  class SnapshotNormalizer
    #: (tree: AssociationTree, ignore_policy: IgnorePolicy, traversal: AssociationTraversal) -> void
    def initialize(tree:, ignore_policy:, traversal:)
      @tree = tree
      @ignore_policy = ignore_policy
      @traversal = traversal
      @structural_columns = {} #: Hash[String, Array[String]]
    end

    #: (untyped, reifier: untyped) -> RecordSnapshot?
    def call(record, reifier:)
      reflections = reflections_for(record, @tree, '')
      normalize_record(record, @tree, '', reifier, reflections)
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @ignore_policy: IgnorePolicy
    # @rbs @traversal: AssociationTraversal
    # @rbs @structural_columns: Hash[String, Array[String]]

    #: (untyped, AssociationTree, String, untyped, Array[untyped]) -> RecordSnapshot?
    def normalize_record(record, tree, path, reifier, reflections)
      return unless record

      attributes = record.attributes.dup
      excluded_attributes(record, reflections, path).each { |name| attributes.delete(name) }
      RecordSnapshot.new(
        type: record.class.name,
        id: record.id,
        attributes: attributes,
        associations: normalize_associations(record, tree, path, reifier, reflections)
      )
    end

    #: (untyped, Array[untyped], String) -> Array[String]
    def excluded_attributes(record, reflections, path)
      primary_key = record.class.primary_key #: untyped
      primary_keys = primary_key.is_a?(Array) ? primary_key : [primary_key]
      # @type var primary_keys: Array[untyped]
      primary_keys = primary_keys.map { |key| key.to_s } # rubocop:disable Style/SymbolProc
      ignored = @ignore_policy.attributes_for(path)
      structural = @structural_columns.fetch(path, [])
      (primary_keys + ignored + relationship_columns(reflections) + structural).uniq
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
    def association_snapshot(record, reflection, subtree, path, reifier)
      associated = record.public_send(reflection.name)
      records = if AssociationSnapshot.collection_kind?(reflection.macro)
                  associated.to_a
                else
                  Array(associated).compact
                end
      child_path = Support.association_path(path, reflection.name.to_s)
      @structural_columns[child_path] ||= @traversal.incoming_relationship_columns(reflection)
      AssociationSnapshot.new(
        kind: reflection.macro,
        records: normalize_children(records, subtree, child_path, reifier)
      )
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
