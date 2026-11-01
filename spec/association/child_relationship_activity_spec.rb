# frozen_string_literal: true

require_relative '../support/association_database'

# Activity applies a child's own update in place, replacing its attributes.
# An update to a key that one of the child's associations, or a through above
# it, follows changes those associations too. Both used to keep the old
# target until something else rebuilt the branch, so the change showed up in
# a later step, credited to whoever saved that.
RSpec.describe 'Activity when a child changes a key its associations follow' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedComment, TrackedAuthorship, TrackedArticle, TrackedAuthor].each(&:delete_all)
  end

  def reviewer_names(snapshot)
    snapshot.associations.fetch('comments').records.map do |comment|
      comment.associations.fetch('reviewer').records.map do |author|
        author.attributes.fetch('name')
      end
    end
  end

  it "reports a comment's new reviewer in the step of the comment's update" do
    ann = TrackedAuthor.create!(name: 'Ann')
    bob = TrackedAuthor.create!(name: 'Bob')
    article = TrackedArticle.create!(title: 'Reviewed')
    comment = article.comments.create!(body: 'comment', reviewer: ann)
    swap_start = Time.now.utc
    PaperTrail.request(whodunnit: 'swapper') { comment.update!(reviewer: bob) }
    swap_end = Time.now.utc
    PaperTrail.request(whodunnit: 'editor') { article.update!(title: 'Edited') }
    options = { associations: ['comments.reviewer'] }

    steps = PaperTrailDiff.activity_timeline(article, snapshots: true, **options)
    window = PaperTrailDiff.analyze(article, within: swap_start..swap_end, activity: true,
                                             **options)
    to_edit = PaperTrailDiff.analyze(article, from: article.versions.first,
                                              to: article.versions.last, activity: true, **options)

    reviewers = steps.reject(&:empty?).map do |step|
      [step.source_boundary.whodunnit, reviewer_names(step.to_snapshot)]
    end
    expect(reviewers).to eq([[nil, []], [nil, [['Ann']]], ['swapper', [['Bob']]],
                             ['editor', [['Bob']]]])
    expect(reviewer_names(window.to_snapshot)).to eq([['Bob']])
    changed = window.diff.associations.fetch('comments').changed
    expect(changed.map { |change| change.associations.keys }).to eq([['reviewer']])
    expect(reviewer_names(to_edit.to_snapshot)).to eq([['Bob']])
  end

  # `contributors` goes through authorships; the authorship read under each
  # contributor is the same row that joins them.
  it 'removes a contributor whose authorship moves to another article' do
    author = TrackedAuthor.create!(name: 'Ann')
    article = TrackedArticle.create!(title: 'Kept')
    other = TrackedArticle.create!(title: 'Other')
    authorship = TrackedAuthorship.create!(article: article, author: author, role: 'writer')
    PaperTrail.request(whodunnit: 'mover') { authorship.update!(article: other) }
    PaperTrail.request(whodunnit: 'editor') { article.update!(title: 'Edited') }

    steps = PaperTrailDiff.activity_timeline(article, associations: ['contributors.authorships'],
                                                      snapshots: true)

    contributors = steps.reject(&:empty?).map do |step|
      [step.source_boundary.whodunnit,
       step.to_snapshot.associations.fetch('contributors').records.map(&:id)]
    end
    expect(contributors).to eq([[nil, []], [nil, [author.id]], ['mover', []], ['editor', []]])
  end
end
