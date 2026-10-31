# frozen_string_literal: true

require 'paper_trail'

# PT-AT stamps every version saved in a transaction with the transaction's id,
# kept on the request until an after_commit it adds to each model versioned
# after PT-AT loads. A fixture model versioned before then, as when a run loads
# spec/unit before spec/association, keeps the first id it saw, so every later
# version shares it and reads as one transaction. Clear it the same way for
# every versioned model, whichever loaded first.
module PaperTrailTransactionReset
  def has_paper_trail(...)
    super.tap do
      after_commit { PaperTrail.request.try(:clear_transaction_id) }
      after_rollback { PaperTrail.request.try(:clear_transaction_id) }
    end
  end
end

PaperTrail::Model::ClassMethods.prepend(PaperTrailTransactionReset)
