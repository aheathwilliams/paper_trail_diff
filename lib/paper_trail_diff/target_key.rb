# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # The foreign key a change row stands for when it adds or removes a
  # `belongs_to` target: the owner's key, which a version of the owner saved,
  # though the diff reports the change on the association. A polymorphic
  # key's type column is part of it: a target of another type with the same
  # id changes only the type.
  module TargetKey
    CHANGES = %i[added removed].freeze
    private_constant :CHANGES

    # The columns of `owner`'s `belongs_to` key the row's record was set,
    # cleared or replaced as, or nil for any other row.
    #: (ChangeRow, RecordReference) -> Array[String]?
    def self.names(row, owner)
      return unless row.association_kind == :belongs_to && CHANGES.include?(row.change)

      reflection = Support.constant(owner.type).reflect_on_association(row.association_path.last)
      return unless reflection&.belongs_to?

      names = [reflection.foreign_key.to_s]
      reflection.polymorphic? ? names << reflection.foreign_type.to_s : names
    rescue NameError
      nil
    end
  end
end
