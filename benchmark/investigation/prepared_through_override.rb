# frozen_string_literal: true

# Load after spec_helper to test the unvalidated through optimization against
# the existing suite. This intentionally exposes a historical-membership mismatch.
PaperTrailDiff::PreparedHistoryLoader.prepend(Module.new do
  def deferred_macro?(_reflection)
    false
  end
end)
