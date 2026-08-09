# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Shared entry construction for internal traversal collaborators.
  class TraversalEmitter
    #: (^(TraversalEntry) -> void) -> void
    def initialize(receiver)
      @receiver = receiver
    end

    private

    # @rbs @receiver: ^(TraversalEntry) -> void

    #: (kind: Symbol, context: traversal_context, association_path: traversal_association_path, record_path: traversal_record_path, value: untyped, ?association_kind: Symbol?, ?state: traversal_state?, ?attribute: String?) -> void
    def emit( # rubocop:disable Metrics/ParameterLists
      kind:,
      context:,
      association_path:,
      record_path:,
      value:,
      association_kind: nil,
      state: nil,
      attribute: nil
    )
      @receiver.call(
        TraversalEntry.new(
          kind: kind,
          context: context,
          association_path: association_path,
          record_path: record_path,
          association_kind: association_kind,
          state: state,
          attribute: attribute,
          value: value
        )
      )
    end
  end
  private_constant :TraversalEmitter
end
