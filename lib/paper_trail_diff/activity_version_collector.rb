# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Collects root and selected-descendant versions relevant to one root history range.
  class ActivityVersionCollector
    #: (untyped, root_versions: Array[untyped], tree: AssociationTree, traversal: AssociationTraversal) -> void
    def initialize(record, root_versions:, tree:, traversal:)
      @record = record
      @root_versions = root_versions
      @tree = tree
      @traversal = traversal
      @versions = {} #: Hash[Array[untyped], untyped]
    end

    #: () -> Array[untyped]
    def call
      add_versions(@root_versions)
      collect_tree(@record.class, [@record.id], @tree, path: '') unless @tree.empty?
      @versions.values.sort_by { |version| Support.chronological_version_key(version) }.freeze
    end

    private

    # @rbs @record: untyped
    # @rbs @root_versions: Array[untyped]
    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @versions: Hash[Array[untyped], untyped]

    #: (untyped, Array[untyped], AssociationTree, path: String) -> void
    def collect_tree(parent_class, parent_ids, tree, path:)
      parent = group(parent_class, parent_ids)
      add_versions(parent.fetch(:versions)) unless path.empty?
      @traversal.reflections_for(parent_class, tree, path: path).each do |reflection|
        subtree = tree.child(reflection.name)
        next unless subtree

        collect_reflection(parent, reflection, subtree, path)
      end
    end

    #: (Hash[Symbol, untyped], untyped, AssociationTree, String) -> void
    def collect_reflection(parent, reflection, subtree, path)
      groups = edge_groups(parent, reflection)
      groups.each_value do |group|
        add_versions(group.fetch(:versions))
        next if subtree.empty?

        child_path = join_path(path, reflection.name.to_s)
        collect_tree(group.fetch(:model), group.fetch(:ids), subtree, path: child_path)
      end
    end

    #: (Hash[Symbol, untyped], untyped) -> Hash[String, untyped]
    def edge_groups(parent, reflection)
      return through_groups(parent, reflection) if reflection.options[:through]

      case reflection.macro
      when :belongs_to
        belongs_to_groups(parent.fetch(:model), parent.fetch(:versions), reflection)
      when :has_one, :has_many
        direct_child_groups(parent.fetch(:model), parent.fetch(:ids), reflection)
      when :has_and_belongs_to_many
        habtm_groups(parent.fetch(:model), parent.fetch(:versions), reflection)
      else
        {}
      end
    end

    #: (Hash[Symbol, untyped], untyped) -> Hash[String, untyped]
    def through_groups(parent, reflection)
      through = reflection.through_reflection
      intermediate = edge_groups(parent, through)
      result = {} #: Hash[String, untyped]
      intermediate.each_value do |group|
        add_versions(group.fetch(:versions))
        source = reflection.source_reflection
        children = edge_groups(group, source)
        merge_groups!(result, children)
      end
      result
    end

    #: (untyped, Array[untyped], untyped) -> Hash[String, untyped]
    def belongs_to_groups(parent_class, parent_versions, reflection)
      rows = parent_class.paper_trail.version_association_class.where(
        version_id: parent_versions.map(&:id),
        foreign_key_name: reflection.foreign_key.to_s
      ).to_a
      identity_groups(rows, reflection)
    end

    #: (untyped, Array[untyped], untyped) -> Hash[String, untyped]
    def direct_child_groups(parent_class, parent_ids, reflection)
      rows = parent_class.paper_trail.version_association_class.where(
        foreign_key_name: reflection.foreign_key.to_s,
        foreign_key_id: parent_ids
      ).includes(:version).to_a
      versions = rows.filter_map do |row|
        row.version if related_parent_type?(row, parent_class)
      end
      version_groups(versions, reflection.klass)
    end

    #: (untyped, Array[untyped], untyped) -> Hash[String, untyped]
    def habtm_groups(parent_class, parent_versions, reflection)
      transaction_ids = parent_versions.filter_map do |version|
        version.transaction_id if version.respond_to?(:transaction_id)
      end
      rows = parent_class.paper_trail.version_association_class.where(
        version_id: transaction_ids,
        foreign_key_name: reflection.name.to_s
      ).to_a
      identity_groups(rows, reflection)
    end

    #: (Array[untyped], untyped) -> Hash[String, untyped]
    def identity_groups(rows, reflection)
      identities = rows.group_by { |row| target_class(reflection, row) }
      groups = {} #: Hash[String, untyped]
      identities.each do |model_class, class_rows|
        next unless model_class

        ids = class_rows.map(&:foreign_key_id).compact.uniq
        groups[model_class.name] = group(model_class, ids)
      end
      groups
    end

    #: (Array[untyped], untyped) -> Hash[String, untyped]
    def version_groups(versions, expected_class)
      ids = versions.filter_map do |version|
        version.item_id if version_matches_model?(version, expected_class)
      end.uniq
      return {} if ids.empty?

      { expected_class.name => group(expected_class, ids) }
    end

    #: (untyped, Array[untyped]) -> Hash[Symbol, untyped]
    def group(model_class, ids)
      { model: model_class, ids: ids, versions: versions_for(model_class, ids) }
    end

    #: (Hash[String, untyped], Hash[String, untyped]) -> void
    def merge_groups!(destination, source)
      source.each do |name, incoming|
        existing = destination[name]
        unless existing
          destination[name] = incoming
          next
        end

        ids = (existing.fetch(:ids) | incoming.fetch(:ids))
        destination[name] = group(existing.fetch(:model), ids)
      end
    end

    #: (untyped, Array[untyped]) -> Array[untyped]
    def versions_for(model_class, ids)
      return [] if ids.empty?

      version_class = model_class.paper_trail.version_class
      version_class.where(
        item_type: model_class.base_class.name,
        item_id: ids
      ).to_a.select { |version| in_range?(version) }
    end

    #: (untyped, untyped) -> untyped
    def target_class(reflection, row)
      return reflection.klass unless reflection.polymorphic?

      Object.const_get(row.foreign_type.to_s) unless row.foreign_type.to_s.empty?
    rescue NameError
      nil
    end

    #: (untyped, untyped) -> bool
    def related_parent_type?(row, parent_class)
      type = row.foreign_type.to_s
      type.empty? || [parent_class.name, parent_class.base_class.name].include?(type)
    end

    #: (untyped, untyped) -> bool
    def version_matches_model?(version, model_class)
      version.item_type.to_s == model_class.base_class.name.to_s
    end

    #: (Array[untyped]) -> void
    def add_versions(versions)
      versions.each { |version| @versions[[version.class.name, version.id]] = version }
    end

    #: (untyped) -> bool
    def in_range?(version)
      Support.compare_versions(@root_versions.first, version) <= 0 &&
        Support.compare_versions(version, @root_versions.last) <= 0
    end

    #: (String, String) -> String
    def join_path(parent, name)
      parent.empty? ? name : "#{parent}.#{name}"
    end
  end
end
