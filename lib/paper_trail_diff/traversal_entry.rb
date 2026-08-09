# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # One immutable location and value emitted while walking a Diff tree.
  class TraversalEntry
    CONTEXTS = %i[change included_state].freeze
    STATES = %i[before after].freeze
    private_constant :CONTEXTS, :STATES

    attr_reader :kind #: Symbol
    attr_reader :context #: traversal_context
    attr_reader :association_path #: traversal_association_path
    attr_reader :record_path #: traversal_record_path
    attr_reader :association_kind #: Symbol?
    attr_reader :state #: traversal_state?
    attr_reader :attribute #: String?
    attr_reader :value #: untyped

    #: (kind: Symbol, context: traversal_context, ?association_path: traversal_association_path, ?record_path: traversal_record_path, ?association_kind: Symbol?, ?state: traversal_state?, ?attribute: String?, ?value: untyped) -> void
    def initialize( # rubocop:disable Metrics/ParameterLists
      kind:,
      context:,
      association_path: [],
      record_path: [],
      association_kind: nil,
      state: nil,
      attribute: nil,
      value: nil
    )
      validate!(context, state)
      @kind = kind
      @context = context
      @association_path = immutable_names(association_path)
      @record_path = Support.immutable_copy(record_path)
      @association_kind = association_kind
      @state = state
      @attribute = Support.immutable_copy(attribute&.to_s)
      @value = Support.immutable_copy(value)
      freeze
    end

    #: () -> bool
    def change?
      context == :change
    end

    #: () -> bool
    def included_state?
      context == :included_state
    end

    #: () -> String?
    def association
      association_path.last
    end

    #: () -> RecordReference?
    def record
      record_path.last
    end

    #: () -> Hash[Symbol, untyped]
    def to_h
      {
        kind: kind,
        context: context,
        association_path: Support.serialize(association_path),
        record_path: Support.serialize(record_path),
        association_kind: association_kind,
        state: state,
        attribute: attribute,
        value: Support.serialize(value)
      }
    end

    private

    #: (Symbol, Symbol?) -> void
    def validate!(candidate_context, candidate_state)
      unless CONTEXTS.include?(candidate_context)
        raise ArgumentError, "unsupported traversal context: #{candidate_context.inspect}"
      end
      return if candidate_state.nil? || STATES.include?(candidate_state)

      raise ArgumentError, "unsupported traversal state: #{candidate_state.inspect}"
    end

    #: (traversal_association_path) -> traversal_association_path
    def immutable_names(names)
      names.map { |name| Support.immutable_copy(name.to_s) }.freeze
    end
  end
end
