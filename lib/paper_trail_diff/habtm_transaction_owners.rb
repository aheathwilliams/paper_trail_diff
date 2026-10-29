# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # PT-AT records HABTM members under a transaction id and the association's
  # name, with nothing naming the record they belong to. When more than one
  # record that can own that name saved a version in the transaction, their
  # members are mixed together and none of them can be read back.
  class HabtmTransactionOwners
    #: (untyped, untyped) -> void
    def initialize(owner_class, reflection)
      @versions = owner_class.paper_trail.version_class
      @associations = owner_class.paper_trail.version_association_class
      @name = reflection.name.to_s
      @owner_types = {} #: Hash[String, bool]
    end

    # The given transactions (one id or several) in which more than one
    # possible owner saved a version, as strings.
    #: (untyped) -> Array[String]
    def shared(transaction_ids)
      items = @versions.where(transaction_id: transaction_ids).distinct
                       .pluck(:transaction_id, :item_type, :item_id)
      owners = items.select { |_, type, _| owner_type?(type) }
      owners.group_by { |transaction_id, _, _| transaction_id.to_s }
            .filter_map { |transaction_id, rows| transaction_id if rows.size > 1 }
    end

    # Members recorded in a shared transaction cannot be told apart. With no
    # members recorded, every owner had none, so that reads correctly.
    #: (untyped) -> bool
    def ambiguous?(transaction_id)
      shared(transaction_id).any? &&
        @associations.exists?(version_id: transaction_id, foreign_key_name: @name)
    end

    #: (untyped) -> void
    def ensure_single_owner!(transaction_id)
      return unless ambiguous?(transaction_id)

      message = "HABTM history is ambiguous for #{@name} at transaction #{transaction_id}: " \
                "more than one record with a #{@name} association saved a version in it, " \
                'and PT-AT does not record which members belong to which record'
      raise IncompleteAssociationHistoryError, message
    end

    private

    # @rbs @versions: untyped
    # @rbs @associations: untyped
    # @rbs @name: String
    # @rbs @owner_types: Hash[String, bool]

    # Versions name the base class, so a HABTM declared on a subclass counts.
    # A type that names no model may have recorded members when it existed.
    #: (String) -> bool
    def owner_type?(type)
      @owner_types.fetch(type) do
        model_class = AssociationTraversal.named_class(type)
        @owner_types[type] =
          !model_class.respond_to?(:reflect_on_association) ||
          [model_class, *model_class.descendants].any? do |candidate|
            candidate.reflect_on_association(@name)&.macro == :has_and_belongs_to_many
          end
      end
    end
  end
end
