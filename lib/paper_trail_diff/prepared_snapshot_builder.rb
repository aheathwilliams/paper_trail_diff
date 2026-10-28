# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Normalizes supported recorded graphs without historical ActiveRecord instances.
  class PreparedSnapshotBuilder
    #: (AssociationTraversal) -> void
    def initialize(traversal)
      @traversal = traversal
      @loader = DirectRecordStateLoader.new
    end

    #: (untyped, untyped, tree: AssociationTree, normalizer: SnapshotNormalizer, history: PreparedHistory?) -> [bool, RecordSnapshot?]
    def call(version, boundary, tree:, normalizer:, history:)
      return [true, nil] unless version.object

      state = @loader.call(version)
      return [false, nil] unless state

      build(state, boundary, tree, normalizer, history, path: '')
    end

    private

    # @rbs @traversal: AssociationTraversal
    # @rbs @loader: DirectRecordStateLoader

    #: (PreparedRecordState, untyped, AssociationTree, SnapshotNormalizer, PreparedHistory?, path: String, ?incoming: untyped) -> [bool, RecordSnapshot?]
    def build(state, boundary, tree, normalizer, history, path:, incoming: nil) # rubocop:disable Metrics/ParameterLists
      associations = {} #: snapshot_associations
      @traversal.reflections_for(state.model_class, tree, path: path).each do |reflection|
        return [false, nil] unless history

        handled, snapshot = association(state, reflection, boundary, tree, normalizer, history,
                                        path)
        return [false, nil] unless handled && snapshot

        associations[reflection.name.to_s] = snapshot
      end
      [true, normalizer.from_state(state, tree: tree, path: path,
                                          incoming: incoming, associations: associations)]
    end

    #: (PreparedRecordState, untyped, untyped, AssociationTree, SnapshotNormalizer, PreparedHistory, String) -> [bool, AssociationSnapshot?]
    def association(owner, reflection, boundary, tree, normalizer, history, path) # rubocop:disable Metrics/ParameterLists
      handled, states = history.snapshot_states(owner, reflection, boundary)
      return [false, nil] unless handled

      subtree = tree.child(reflection.name)
      return [false, nil] unless subtree

      child_path = Support.association_path(path, reflection.name.to_s)
      records = [] #: Array[RecordSnapshot]
      states.each do |state|
        supported, snapshot = build(state, boundary, subtree, normalizer, history,
                                    path: child_path, incoming: reflection)
        return [false, nil] unless supported && snapshot

        records << snapshot
      end
      [true, AssociationSnapshot.new(kind: reflection.macro, records: records)]
    end
  end
end
