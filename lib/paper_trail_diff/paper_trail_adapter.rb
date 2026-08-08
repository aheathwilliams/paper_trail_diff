# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # PaperTrail/ActiveRecord boundary that produces plain record snapshots.
  class PaperTrailAdapter
    #: (associations: Array[String | Symbol], ignore: ignore_option) -> void
    def initialize(associations:, ignore:)
      @association_tree = AssociationTree.build(associations)
      @ignore_policy = IgnorePolicy.build(ignore, association_paths: @association_tree.paths)
      @traversal = AssociationTraversal.new(@association_tree)
      @structural_columns = {} #: Hash[String, Array[String]]
    end

    #: (untyped, untyped) -> Diff
    def compare(from_version, to_version)
      validate_version_pair!(from_version, to_version)
      Engine.compare(snapshot_for(from_version), snapshot_for(to_version))
    end

    #: (untyped, from: untyped, to: untyped) -> Array[Step]
    def timeline(record, from:, to:)
      TimelineBuilder.new(record, from: from, to: to, snapshotter: method(:snapshot_for)).build
    end

    #: (untyped, from: untyped, to: untyped) -> Array[Step]
    def activity_timeline(record, from:, to:)
      prepare_traversal!(record.class)
      ActivityTimelineBuilder.new(
        record,
        from: from,
        to: to,
        tree: @association_tree,
        snapshotter: method(:snapshot_at)
      ).build
    end

    #: (untyped, from: untyped, to: untyped) -> Analysis
    def analyze(record, from:, to:)
      TimelineBuilder.new(record, from: from, to: to, snapshotter: method(:snapshot_for)).analyze
    end

    private

    # @rbs @association_tree: AssociationTree
    # @rbs @ignore_policy: IgnorePolicy
    # @rbs @traversal: AssociationTraversal
    # @rbs @structural_columns: Hash[String, Array[String]]

    #: (untyped) -> RecordSnapshot?
    def snapshot_for(version)
      snapshot_at(version, version)
    end

    #: (untyped, untyped) -> RecordSnapshot?
    def snapshot_at(root_version, context_version)
      model_class = version_model_class(root_version)
      prepare_traversal!(model_class)
      reflections = @traversal.reflections_for(model_class, @association_tree, path: '')
      record = root_version.reify(dup: true)
      reifier = HistoricalAssociationReifier.new(context_version, habtm_version: root_version)
      reifier.reify(record, reflections) if record && !reflections.empty?
      normalize_record(
        record,
        tree: @association_tree,
        path: '',
        reifier: reifier,
        reflections: reflections
      )
    end

    #: (untyped, tree: AssociationTree, path: String, reifier: HistoricalAssociationReifier, reflections: Array[untyped]) -> RecordSnapshot?
    def normalize_record(record, tree:, path:, reifier:, reflections:)
      return unless record

      attributes = record.attributes.dup
      excluded_attributes(record, reflections, path).each { |name| attributes.delete(name) }
      RecordSnapshot.new(
        type: record.class.name,
        id: record.id,
        attributes: attributes,
        associations: normalize_associations(
          record,
          tree: tree,
          path: path,
          reifier: reifier,
          reflections: reflections
        )
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

    #: (untyped, tree: AssociationTree, path: String, reifier: HistoricalAssociationReifier, reflections: Array[untyped]) -> Hash[String, AssociationSnapshot]
    def normalize_associations(record, tree:, path:, reifier:, reflections:)
      associations = {} #: Hash[String, AssociationSnapshot]
      reflections.each do |reflection|
        name = reflection.name.to_s
        subtree = tree.child(name)
        raise ArgumentError, "missing traversal subtree: #{name}" unless subtree

        associations[name] = association_snapshot(record, reflection, subtree, path, reifier)
      end
      associations
    end

    #: (untyped, untyped, AssociationTree, String, HistoricalAssociationReifier) -> AssociationSnapshot
    def association_snapshot(record, reflection, subtree, path, reifier)
      associated = record.public_send(reflection.name)
      records = if AssociationSnapshot.collection_kind?(reflection.macro)
                  associated.to_a
                else
                  Array(associated).compact
                end
      child_path = join_path(path, reflection.name.to_s)
      @structural_columns[child_path] ||= @traversal.incoming_relationship_columns(reflection)
      AssociationSnapshot.new(
        kind: reflection.macro,
        records: normalize_children(records, subtree, child_path, reifier)
      )
    end

    #: (Array[untyped], AssociationTree, String, HistoricalAssociationReifier) -> Array[RecordSnapshot]
    def normalize_children(records, tree, path, reifier)
      reflections_by_class = {} #: Hash[String, Array[untyped]]
      records.filter_map do |child|
        type = child.class.name
        reflections = reflections_by_class[type] ||=
          @traversal.reflections_for(child.class, tree, path: path)
        reifier.reify(child, reflections) unless reflections.empty?
        normalize_record(
          child,
          tree: tree,
          path: path,
          reifier: reifier,
          reflections: reflections
        )
      end
    end

    #: (untyped) -> void
    def prepare_traversal!(model_class)
      return if @association_tree.empty?

      ensure_association_tracking!
      @traversal.validate!(model_class)
    end

    #: (String, String) -> String
    def join_path(parent, name)
      parent.empty? ? name : "#{parent}.#{name}"
    end

    #: (untyped) -> untyped
    def version_model_class(version)
      subtype = version.item_subtype if version.respond_to?(:item_subtype)
      model_type = subtype.to_s.empty? ? version.item_type.to_s : subtype.to_s
      Object.const_get(model_type)
    end

    #: () -> void
    def ensure_association_tracking!
      paper_trail = Object.const_get(:PaperTrail) #: untyped
      config = paper_trail.config #: untyped
      available = defined?(::PaperTrailAssociationTracking) &&
                  config.respond_to?(:track_associations?) &&
                  config.track_associations?
      return if available

      message = 'association tracking must be loaded and enabled to compare associations'
      raise AssociationTrackingUnavailableError, message
    end

    #: (untyped, untyped) -> void
    def validate_version_pair!(from_version, to_version)
      return if version_item_identity(from_version) == version_item_identity(to_version)

      raise VersionMismatchError, 'versions must belong to the same PaperTrail item'
    end

    #: (untyped) -> Array[String]
    def version_item_identity(version)
      [version.item_type.to_s, version.item_id.to_s]
    rescue NoMethodError => e
      raise VersionMismatchError, 'expected PaperTrail version endpoints', cause: e
    end
  end
end
