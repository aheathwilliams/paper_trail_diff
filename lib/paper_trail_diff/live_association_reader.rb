# frozen_string_literal: true
# rbs_inline: enabled

module PaperTrailDiff
  # Leaves live ActiveRecord associations untouched while sharing snapshot normalization.
  class LiveAssociationReader
    #: (untyped, Array[untyped]) -> void
    def reify(_record, _reflections); end
  end
end
