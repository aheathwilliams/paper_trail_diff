# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Advances scalar-only root events while retaining already reconstructed associations.
  class ActivityRootSnapshotRefresher
    #: (tree: AssociationTree, traversal: AssociationTraversal, normalizer: SnapshotNormalizer, record_after: untyped, changeset: untyped, partial_snapshotter: untyped, ?record_transition: untyped) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      tree:,
      traversal:,
      normalizer:,
      record_after:,
      changeset:,
      partial_snapshotter:,
      record_transition: nil
    )
      @tree = tree
      @traversal = traversal
      @normalizer = normalizer
      @record_after = record_after
      @changeset = changeset
      @partial_snapshotter = partial_snapshotter
      @record_transition = record_transition
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
      model_class = RecordedClass.for(version)
      return [false, nil] unless same_record?(previous, model_class, version)

      changed = changed_columns(version, model_class)
      return [false, nil] if changed.empty?

      # A change of STI class can change the associations themselves.
      record = @record_after.call(version)
      return [false, nil] unless record && recorded_class(record) == model_class

      branches = branches_to_refresh(model_class, changed)
      partial = nil #: RecordSnapshot?
      unless branches.empty?
        partial = @partial_snapshotter.call(root_endpoint, context_endpoint, branches)
      end
      return [false, nil] if !branches.empty? && !partial

      attributes = @normalizer.attributes_for(record, tree: @tree, path: '')

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
    # @rbs @record_transition: untyped
    # @rbs @unsupported_branches: Hash[String, Array[String]]
    # @rbs @relationship_reflections: Hash[String, Array[untyped]]

    # The columns the version changed, from its changeset and from the states
    # either side of it. The changeset leaves out columns that `only:` or
    # `ignore:` exclude and keys written without a version, which the states
    # hold.
    #: (untyped, untyped) -> Array[String]
    def changed_columns(version, model_class)
      changes = @changeset.call(version, model_class)
      names = changes.respond_to?(:each_key) ? changes.each_key.map(&:to_s) : [] #: Array[String]
      transition = @record_transition&.call(version)
      return names unless transition

      before, after = transition
      names | (before.keys | after.keys).filter_map do |name|
        name.to_s unless before[name] == after[name]
      end
    end

    #: (untyped) -> untyped
    def recorded_class(record)
      record.is_a?(PreparedRecordState) ? record.model_class : record.class
    end

    #: (untyped, Array[String]) -> Array[String]
    def branches_to_refresh(model_class, changed)
      (unsupported_branches(model_class) + changed_relationship_branches(model_class, changed))
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

    # A polymorphic target's class is known only per record, so it cannot be
    # checked here; a target that is not versioned raises when it is read.
    #: (untyped) -> bool
    def direct_versioned_reflection?(reflection)
      return true if reflection.polymorphic?
      return false if reflection.options[:through]
      return false if reflection.macro == :has_and_belongs_to_many

      paper_trail = Object.const_get(:PaperTrail) #: untyped
      paper_trail.request.enabled_for_model?(reflection.klass)
    rescue NameError
      false
    end

    # The snapshot names the record's class, which for an STI subclass is not
    # the base class the version names.
    #: (RecordSnapshot, untyped, untyped) -> bool
    def same_record?(snapshot, model_class, version)
      snapshot.type.to_s == model_class.name.to_s &&
        snapshot.id.to_s == Endpoint.identity(version).fetch(1)
    end

    #: (untyped, Array[String]) -> Array[String]
    def changed_relationship_branches(model_class, changed)
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
