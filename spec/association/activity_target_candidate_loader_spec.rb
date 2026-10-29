# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe PaperTrailDiff::ActivityTargetCandidateLoader do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedArticle, TrackedAuthor].each(&:delete_all)
  end

  def targets(article, range)
    reflection = TrackedArticle.reflect_on_association(:author)
    described_class.new(TrackedArticle, [article.id], reflection, range).call.map(&:foreign_key_id)
  end

  # PT-AT records the author after each version's change: the version before
  # the window names the author at its start, and the version that closes it
  # names the author after its end.
  it 'reads the targets held inside the range and none named by its closing version' do
    first, second, third = %w[Ann Bea Cy].map { |name| TrackedAuthor.create!(name: name) }
    article = TrackedArticle.create!(title: 'Moving', author: first)
    start = Time.now.utc
    article.update!(author: second)
    finish = Time.now.utc
    article.update!(author: third)
    closing = article.versions.reload.last

    expect(targets(article, PaperTrailDiff::ActivityRange.new(start, closing)))
      .to contain_exactly(first.id, second.id)
    expect(targets(article, PaperTrailDiff::ActivityRange.new(start, finish)))
      .to contain_exactly(first.id, second.id, third.id)
  end
end
