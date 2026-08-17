# frozen_string_literal: true

require_relative '../support/core_database'

RSpec.describe PaperTrailDiff::Support do
  describe '.versioned?' do
    it 'distinguishes a model that called has_paper_trail from one that did not' do
      expect(described_class.versioned?(CoreArticle)).to be(true)
      expect(described_class.versioned?(CoreComment)).to be(false)
    end

    # The reason this predicate is worth pinning: PaperTrail defines
    # `paper_trail` on every ActiveRecord model, so the shorter spelling of this
    # check answers true for models that never called `has_paper_trail`. It looks
    # right and is wrong for exactly the case the predicate exists to catch.
    it 'does not settle for responding to paper_trail, which every model does' do
      expect(CoreComment).to respond_to(:paper_trail)
      expect(described_class.versioned?(CoreComment)).to be(false)
    end

    it 'answers for a model whose versions live in a custom class' do
      expect(described_class.versioned?(UuidKeyedArticle)).to be(true)
    end

    it 'answers false for a class that is not a model at all' do
      expect(described_class.versioned?(Object)).to be(false)
    end
  end
end
