# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The foreign key a change row stands for when it adds or removes a
  # `belongs_to` target: the owner's key, which a version of the owner saved,
  # though the diff reports the change on the association.
  module TargetKey
    CHANGES = %i[added removed].freeze
    private_constant :CHANGES

    # The key of `owner`'s `belongs_to` the row's record was set, cleared or
    # replaced as, or nil for any other row.
    #: (ChangeRow, RecordReference) -> String?
    def self.name(row, owner)
      return unless row.association_kind == :belongs_to && CHANGES.include?(row.change)

      reflection = Support.constant(owner.type).reflect_on_association(row.association_path.last)
      reflection.foreign_key.to_s if reflection&.belongs_to?
    rescue NameError
      nil
    end
  end
end
