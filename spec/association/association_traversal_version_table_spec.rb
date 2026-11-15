# frozen_string_literal: true

require_relative '../support/version_table_database'

RSpec.describe PaperTrailDiff::AssociationTraversal do
  describe '.unsupported_reason' do
    def reason(name)
      reflection = SplitShelf.reflect_on_association(name)
      described_class.unsupported_reason(SplitShelf, reflection)
    end

    it 'refuses an association whose ends keep versions in different tables' do
      expect(reason(:books)).to start_with('SplitShelf#books keeps versions in versions')
    end
  end
end
