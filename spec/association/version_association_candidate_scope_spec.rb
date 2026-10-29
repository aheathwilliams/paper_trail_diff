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

  # SQL Server quotes a bare time as `datetime`, rounded to 1/300 second: a
  # 2.0ms start reads as 3ms and a 5.0ms end as 7ms. Times compared as the
  # column stores them keep a version saved a fraction of a millisecond away
  # on the side it was saved.
  it 'compares boundaries at the precision the versions were saved with' do
    article = TrackedArticle.create!(title: 'Precise window')
    comment = article.comments.create!(body: 'one')
    comment.update!(body: 'two')
    comment.update!(body: 'three')
    created, inside, after = comment.versions.reorder(:id).to_a
    base = Time.utc(2026, 1, 1, 12)
    { created => base, inside => base + 0.0021, after => base + 1.006 }.each do |version, at|
      PaperTrail::Version.where(id: version.id).update_all(created_at: at)
    end
    relation = PaperTrail::VersionAssociation.joins(:version)
                                             .where(versions: { item_type: 'TrackedComment' })

    ids = described_class.new(PaperTrail::Version, base + 0.002, end_at: base + 1.005)
                         .call(relation).distinct.pluck(PaperTrail::Version.arel_table[:id])

    expect(ids).to contain_exactly(created.id, inside.id)
  end
end
