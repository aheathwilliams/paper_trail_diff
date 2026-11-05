# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Advances scalar-only root events while retaining already reconstructed associations.
  class ActivityRootSnapshotRefresher
    # `root_state` gives the state a root endpoint's snapshot is built from,
    # where prepared history builds it.
    #: (tree: AssociationTree, traversal: AssociationTraversal, normalizer: SnapshotNormalizer, record_after: untyped, changeset: untyped, partial_snapshotter: untyped, ?record_transition: untyped, ?root_state: untyped) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      tree:,
      traversal:,
      normalizer:,
      record_after:,
      changeset:,
      partial_snapshotter:,
      record_transition: nil,
      root_state: nil
    )
      @tree = tree
      @traversal = traversal
      @normalizer = normalizer
      @record_after = record_after
      @changeset = changeset
      @partial_snapshotter = partial_snapshotter
      @record_transition = record_transition
      @root_state = root_state
      @unsupported_branches = {} #: Hash[String, Array[String]]
      @relationship_reflections = {} #: Hash[String, Array[untyped]]
    end

    # `previous` is the snapshot at the root's `event`, and the result the one
    # at the next event, whose root is read at `root_endpoint`.
    #: (untyped, untyped, RecordSnapshot?, ActivityEvent) -> [bool, RecordSnapshot?]
    def call(root_endpoint, context_endpoint, previous, event)
      return [false, nil] unless previous && event.root?

      record, branches = target(previous, event.version, root_endpoint)
      return [false, nil] unless record && branches

      partial = nil #: RecordSnapshot?
      unless branches.empty?
        partial = @partial_snapshotter.call(root_endpoint, context_endpoint, branches)
        return [false, nil] unless partial
      end
      [true, advanced(previous, record, partial)]
    end

    private

    # The snapshot at a root version starts from the state stored in that
    # version, and the next one from the state at its own root endpoint. Where
    # prepared history built both from those states, the two are compared
    # directly; nothing else needs to be decoded. Otherwise the version's
    # recorded change and the record after it are read.
    #: (RecordSnapshot, untyped, untyped) -> [untyped, Array[String]]?
    def target(previous, version, root_endpoint)
      before = @root_state&.call(version)
      after = before && @root_state&.call(root_endpoint)
      return advance_target(previous, version) unless before && after

      state_target(previous, version, before, after)
    end

    # The state at the next event and the branches whose reads the root's
    # change between the two states can alter. A change of STI class can
    # change the associations themselves, so it is rebuilt in full.
    #: (RecordSnapshot, untyped, PreparedRecordState, PreparedRecordState) -> [PreparedRecordState, Array[String]]?
    def state_target(previous, version, before, after)
      model_class = before.model_class
      return unless after.model_class == model_class && same_record?(previous, model_class, version)

      [after, branches_to_refresh(model_class, differing(before.attributes, after.attributes))]
    end

    # The names of the columns whose values differ between two sets of them.
    #: (Hash[untyped, untyped], Hash[untyped, untyped]) -> Array[String]
    def differing(old, new)
      (old.keys | new.keys).filter_map { |name| name.to_s unless old[name] == new[name] }
    end

    # The record after a root version and the branches its change reaches, or
    # nil when the version cannot be applied to the previous snapshot alone.
    #: (RecordSnapshot, untyped) -> [untyped, Array[String]]?
    def advance_target(previous, version)
      model_class = RecordedClass.for(version)
      return unless same_record?(previous, model_class, version)

      changed = changed_columns(version, model_class)
      return if changed.empty?

      # A change of STI class can change the associations themselves.
      record = @record_after.call(version)
      return unless record && recorded_class(record) == model_class

      [record, branches_to_refresh(model_class, changed)]
    end

    # The previous snapshot with the record's attributes and any branches read
    # again, or the previous snapshot itself when nothing differs.
    #: (RecordSnapshot, untyped, RecordSnapshot?) -> RecordSnapshot
    def advanced(previous, record, partial)
      attributes = @normalizer.attributes_for(record, tree: @tree, path: '')
      associations = previous.associations
      associations = associations.merge(partial.associations) if partial
      return previous if attributes == previous.attributes && associations == previous.associations

      RecordSnapshot.new(type: previous.type, id: previous.id, attributes: attributes,
                         associations: associations)
    end

    # @rbs @tree: AssociationTree
    # @rbs @traversal: AssociationTraversal
    # @rbs @normalizer: SnapshotNormalizer
    # @rbs @record_after: untyped
    # @rbs @changeset: untyped
    # @rbs @partial_snapshotter: untyped
    # @rbs @record_transition: untyped
    # @rbs @root_state: untyped
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
      names | differing(before, after)
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
