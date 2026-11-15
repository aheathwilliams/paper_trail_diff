# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Normalizes recorded graphs from prepared history, reading each member's
  # state without rebuilding its record.
  class PreparedSnapshotBuilder
    #: (AssociationTraversal) -> void
    def initialize(traversal)
      @traversal = traversal
      @loader = DirectRecordStateLoader.new
      @reified = {} #: Hash[Array[untyped], PreparedRecordState?]
    end

    #: (untyped, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer, history: PreparedHistory?) -> RecordSnapshot?
    def call(version, boundary, tree:, normalizer:, history:)
      state = state(version)
      build(state, boundary, tree, normalizer, history, path: '') if state
    end

    # The state `call` builds a version's snapshot from, or nil when the
    # version stored none. A model whose records need their own
    # initialization is read by reifying it, once per version.
    #: (untyped) -> PreparedRecordState?
    def state(version)
      return unless version.object

      @loader.call(version) || @reified.fetch(Support.row_key(version)) do |key|
        @reified[key] = reified_state(version)
      end
    end

    # The current row of a root, given as its state, with its associations as
    # `boundary` reads them. Its attributes are the record's own, as the
    # current snapshot normalizes them, so its model need not be plain; its
    # members are read as a version's are.
    #: (PreparedRecordState, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer, history: PreparedHistory?) -> RecordSnapshot
    def live(state, boundary, tree:, normalizer:, history:)
      build(state, boundary, tree, normalizer, history, path: '')
    end

    # A state at `path` of the tree, with the associations `tree` selects
    # below it as `boundary` reads them.
    #: (PreparedRecordState, untyped, AssociationTree, SnapshotNormalizer, PreparedHistory?, path: String, ?incoming: untyped) -> RecordSnapshot
    def build(state, boundary, tree, normalizer, history, path:, incoming: nil) # rubocop:disable Metrics/ParameterLists
      associations = {} #: snapshot_associations
      @traversal.reflections_for(state.model_class, tree, path: path).each do |reflection|
        unless history
          raise UnsupportedAssociationError,
                "association #{state.model_class.name}##{reflection.name} cannot be read: " \
                'no history was prepared for it'
        end

        associations[reflection.name.to_s] =
          association(state, reflection, boundary, tree, normalizer, history, path)
      end
      normalizer.from_state(state, tree: tree, path: path, incoming: incoming,
                                   associations: associations)
    end

    private

    # @rbs @traversal: AssociationTraversal
    # @rbs @loader: DirectRecordStateLoader
    # @rbs @reified: Hash[Array[untyped], PreparedRecordState?]

    #: (untyped) -> PreparedRecordState?
    def reified_state(version)
      record = Support.reify(version, dup: true, has_many: false, has_one: false,
                                      belongs_to: false, has_and_belongs_to_many: false)
      PreparedRecordState.new(record) if record
    end

    #: (PreparedRecordState, untyped, untyped, AssociationTree, SnapshotNormalizer, PreparedHistory, String) -> AssociationSnapshot
    def association(owner, reflection, boundary, tree, normalizer, history, path) # rubocop:disable Metrics/ParameterLists
      subtree = tree.child(reflection.name) #: AssociationTree
      child_path = Support.association_path(path, reflection.name)
      records = history.snapshot_states(owner, reflection, boundary).map do |state|
        build(state, boundary, subtree, normalizer, history, path: child_path,
                                                             incoming: reflection)
      end
      AssociationSnapshot.new(kind: reflection.macro, records: records)
    end
  end
end
