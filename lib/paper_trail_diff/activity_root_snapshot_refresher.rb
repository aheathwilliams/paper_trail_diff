# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Advances scalar-only root events while retaining already reconstructed associations.
  class ActivityRootSnapshotRefresher
    #: (tree: AssociationTree, traversal: AssociationTraversal, normalizer: SnapshotNormalizer, record_after: untyped, changeset: untyped, partial_snapshotter: untyped) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      tree:,
      traversal:,
      normalizer:,
      record_after:,
      changeset:,
      partial_snapshotter:
    )
      @tree = tree
      @traversal = traversal
      @normalizer = normalizer
      @record_after = record_after
      @changeset = changeset
      @partial_snapshotter = partial_snapshotter
      @unsupported_branches = {} #: Hash[String, Array[String]]
      @relationship_reflections = {} #: Hash[String, Array[untyped]]
    end

    #: (untyped, untyped, RecordSnapshot?, ActivityEvent) -> [bool, RecordSnapshot?]
    def call( # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      root_endpoint,
      context_endpoint,
      previous,
      event
    )
      return [false, nil] unless previous && event.root?

      version = event.version
      model_class = Endpoint.model_class(version)
      return [false, nil] unless same_record?(previous, version)

      changes = @changeset.call(version, model_class)
      return [false, nil] unless changes.respond_to?(:each)

      branches = branches_to_refresh(model_class, changes)
      partial = nil #: RecordSnapshot?
      unless branches.empty?
        partial = @partial_snapshotter.call(root_endpoint, context_endpoint, branches)
      end
      return [false, nil] if !branches.empty? && !partial

      attributes = advanced_attributes(previous, version, changes)
      return [false, nil] unless attributes

      incoming_associations = {} #: snapshot_associations
      incoming_associations = partial.associations if partial
      associations = previous.associations.merge(incoming_associations)
      return [true, previous] if attributes == previous.attributes &&
                                 associations == previous.associations

      [
        true,
        RecordSnapshot.new(
          type: previous.type,
          id: previous.id,
          attributes: attributes,
          associations: associations
        )
      ]
    end

    private

    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @normalizer: SnapshotNormalizer
    # @rbs @record_after: untyped
    # @rbs @changeset: untyped
    # @rbs @partial_snapshotter: untyped
    # @rbs @unsupported_branches: Hash[String, Array[String]]
    # @rbs @relationship_reflections: Hash[String, Array[untyped]]

    #: (RecordSnapshot, untyped, untyped) -> snapshot_attributes?
    def advanced_attributes(previous, version, changes)
      return previous.attributes if changes.empty?

      record = @record_after.call(version)
      return unless record

      @normalizer.attributes_for(record, tree: @tree, path: '')
    end

    #: (untyped, untyped) -> Array[String]
    def branches_to_refresh(model_class, changes)
      (unsupported_branches(model_class) + changed_relationship_branches(model_class, changes))
        .uniq
        .sort
        .freeze
    end

    #: (untyped) -> Array[String]
    def unsupported_branches(model_class)
      key = model_class.name.to_s
      return @unsupported_branches[key] if @unsupported_branches.key?(key)

      @unsupported_branches[key] = @traversal.selected_reflections(
        model_class
      ).filter_map do |path, reflection|
        path.split('.').first unless direct_versioned_reflection?(reflection)
      end.uniq.sort.freeze
    end

    #: (untyped) -> bool
    def direct_versioned_reflection?(reflection)
      return false if reflection.polymorphic? || reflection.options[:through]
      return false if reflection.macro == :has_and_belongs_to_many

      paper_trail = Object.const_get(:PaperTrail) #: untyped
      paper_trail.request.enabled_for_model?(reflection.klass)
    rescue NameError
      false
    end

    #: (RecordSnapshot, untyped) -> bool
    def same_record?(snapshot, version)
      identity = Endpoint.identity(version)
      snapshot.type.to_s == identity.fetch(0) && snapshot.id.to_s == identity.fetch(1)
    end

    #: (untyped, untyped) -> Array[String]
    def changed_relationship_branches(model_class, changes)
      changed = changes.each_key.map(&:to_s)
      root_relationship_reflections(model_class).filter_map do |reflection|
        reflection.name.to_s if changed.intersect?(relationship_columns(reflection))
      end
    end

    #: (untyped) -> Array[untyped]
    def root_relationship_reflections(model_class)
      key = model_class.name.to_s
      @relationship_reflections[key] ||= @traversal.reflections_for(
        model_class,
        @tree,
        path: ''
      ).select { |reflection| reflection.macro == :belongs_to }.freeze
    end

    #: (untyped) -> Array[String]
    def relationship_columns(reflection)
      foreign_keys = Array(reflection.foreign_key)
      # @type var foreign_keys: Array[untyped]
      columns = foreign_keys.map do |name| # rubocop:disable Style/SymbolProc
        name.to_s
      end
      columns << reflection.foreign_type.to_s if reflection.polymorphic?
      columns
    end
  end
end
