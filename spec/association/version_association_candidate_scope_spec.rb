# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe PaperTrailDiff::VersionAssociationCandidateScope do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedReply.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
  end

  it 'keeps start-state and later candidates without retaining removed history' do
    article = TrackedArticle.create!(title: 'Candidate window')
    stable = article.comments.create!(body: 'Stable at start')
    removed = article.comments.create!(body: 'Removed before start')
    removed.destroy!
    start = article.paper_trail.save_with_version
    recent = article.comments.create!(body: 'Created after start')
    finish = article.paper_trail.save_with_version
    later = article.comments.create!(body: 'Created after finish')
    version_class = PaperTrail::Version
    relation = PaperTrail::VersionAssociation.joins(:version).where(
      foreign_key_name: 'article_id',
      foreign_key_id: article.id,
      versions: { item_type: 'TrackedComment' }
    )

    ids = described_class.new(
      version_class,
      start.created_at,
      end_at: finish.created_at
    ).call(relation).distinct.pluck(version_class.arel_table[:item_id])
    forward = described_class.new(
      version_class,
      start.created_at
    ).call(relation).distinct.pluck(version_class.arel_table[:item_id])
    unbounded = described_class.new(
      version_class,
      nil
    ).call(relation).distinct.pluck(version_class.arel_table[:item_id])

    expect(ids).to contain_exactly(stable.id, recent.id)
    expect(forward).to contain_exactly(stable.id, recent.id, later.id)
    expect(unbounded).to contain_exactly(stable.id, removed.id, recent.id, later.id)
  end
end
