# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Collects root and selected-descendant versions relevant to one root history range.
  class ActivityVersionCollector
    #: (untyped, root_versions: Array[untyped], tree: AssociationTree, traversal: AssociationTraversal, ?range_start: untyped, ?range_end: untyped) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      record,
      root_versions:,
      tree:,
      traversal:,
      range_start: root_versions.first,
      range_end: root_versions.last
    )
      @record = record
      @root_versions = root_versions
      @tree = tree
      @traversal = traversal
      @range = ActivityRange.new(range_start, range_end)
      @registry = ActivityEventRegistry.new
    end

    #: () -> Array[ActivityEvent]
    def call
      @registry.add(@root_versions)
      collect_tree(@record.class, [@record.id], @tree, path: '', branch: nil) unless @tree.empty?
      @registry.to_a.sort_by do |event|
        Support.chronological_version_key(event.version)
      end.freeze
    end

    private

    # @rbs @record: untyped
    # @rbs @root_versions: Array[untyped]
    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @range: ActivityRange
    # @rbs @registry: ActivityEventRegistry

    #: (untyped, Array[untyped], AssociationTree, path: String, branch: String?) -> void
    def collect_tree(parent_class, parent_ids, tree, path:, branch:)
      parent = group(parent_class, parent_ids)
      @registry.add(parent.fetch(:versions), branch: branch) unless path.empty?
      @traversal.reflections_for(parent_class, tree, path: path).each do |reflection|
        subtree = tree.child(reflection.name)
        next unless subtree

        selected_branch = branch || reflection.name.to_s
        collect_reflection(parent, reflection, subtree, path, selected_branch)
      end
    end

    #: (Hash[Symbol, untyped], untyped, AssociationTree, String, String) -> void
    def collect_reflection(parent, reflection, subtree, path, branch)
      groups = edge_groups(parent, reflection, branch)
      groups.each_value do |group|
        @registry.add(group.fetch(:versions), branch: branch)
        next if subtree.empty?

        child_path = join_path(path, reflection.name.to_s)
        collect_tree(group.fetch(:model), group.fetch(:ids), subtree,
                     path: child_path, branch: branch)
      end
    end

    #: (Hash[Symbol, untyped], untyped, String) -> Hash[String, untyped]
    def edge_groups(parent, reflection, branch)
      return through_groups(parent, reflection, branch) if reflection.options[:through]

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

    #: (Hash[Symbol, untyped], untyped, String) -> Hash[String, untyped]
    def through_groups(parent, reflection, branch)
      through = reflection.through_reflection
      intermediate = edge_groups(parent, through, branch)
      result = {} #: Hash[String, untyped]
      intermediate.each_value do |group|
        @registry.add(group.fetch(:versions), branch: branch)
        source = reflection.source_reflection
        children = edge_groups(group, source, branch)
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
    def direct_child_groups(parent_class, parent_ids, reflection) # rubocop:disable Metrics/AbcSize
      version_class = parent_class.paper_trail.version_class
      relation = parent_class.paper_trail.version_association_class.joins(:version).where(
        foreign_key_name: reflection.foreign_key.to_s,
        foreign_key_id: parent_ids
      ).where(foreign_type: related_parent_types(parent_class))
      item_ids = relation.where(
        version_class.table_name => { item_type: reflection.klass.base_class.name }
      ).distinct.pluck(version_class.arel_table[:item_id])
      return {} if item_ids.empty?

      { reflection.klass.name => group(reflection.klass, item_ids) }
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
      @range.scope(
        version_class.where(
          item_type: model_class.base_class.name,
          item_id: ids
        )
      ).to_a.select { |version| in_range?(version) }
    end

    #: (untyped, untyped) -> untyped
    def target_class(reflection, row)
      return reflection.klass unless reflection.polymorphic?

      Object.const_get(row.foreign_type.to_s) unless row.foreign_type.to_s.empty?
    rescue NameError
      nil
    end

    #: (untyped) -> Array[String?]
    def related_parent_types(parent_class)
      [nil, '', parent_class.name.to_s, parent_class.base_class.name.to_s].uniq
    end

    #: (untyped) -> bool
    def in_range?(version)
      @range.include?(version)
    end

    #: (String, String) -> String
    def join_path(parent, name)
      parent.empty? ? name : "#{parent}.#{name}"
    end
  end
end
