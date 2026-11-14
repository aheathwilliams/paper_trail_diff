# frozen_string_literal: true

require_relative '../support/association_database'

# A belongs_to target created inside an activity range changes nothing an
# owner shows, unless an owner already named it: a key can name a record
# that does not exist yet where no foreign key constraint forbids it.
RSpec.describe 'Activity when a belongs_to target is created',
               mutant_expression: 'PaperTrailDiff::ActivityBelongsToEventApplier' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedComment, TrackedArticle, TrackedAuthor].each(&:delete_all)
  end

  let(:options) { { associations: ['comments.reviewer'] } }

  def refreshes(&block)
    count = 0
    counting = proc { |original, *args, **kwargs| (count += 1) && original.call(*args, **kwargs) }
    allow_any_instance_of(PaperTrailDiff::BranchSnapshotRefresher)
      .to receive(:refreshed).and_wrap_original(&counting)
    yield
    count
  end

  def changes(steps)
    steps.map do |step|
      step.diff.each_change.map { |entry| [entry.kind, entry.association_path.join('.')] }
    end
  end

  it 'leaves the branch as it was when every owner already holds a target' do
    article = TrackedArticle.create!(title: 'Root')
    article.comments.create!(body: 'first', reviewer: TrackedAuthor.create!(name: 'Ann'))
    reviewer = TrackedAuthor.create!(name: 'Bea')
    article.comments.create!(body: 'second', reviewer: reviewer)

    steps = nil
    count = refreshes { steps = SpecTimelines.activity_timeline(article, **options) }

    expect(changes(steps)).to eq([[[:record_presence_changed, '']], [[:record_added, 'comments']],
                                  [[:record_added, 'comments']]])
    expect(count).to eq(0)
  end

  it 'reports the target at its creation when an owner named it first' do
    article = TrackedArticle.create!(title: 'Root')
    comment = article.comments.create!(body: 'early', reviewer_id: 4242)
    TrackedAuthor.create!(id: 4242, name: 'Late')
    comment.update!(body: 'edited')

    steps = SpecTimelines.activity_timeline(article, **options)

    expect(changes(steps).last(2))
      .to eq([[[:record_changed, 'comments'], [:relationship_added, 'comments.reviewer']],
              [[:record_changed, 'comments'], [:attribute_changed, 'comments']]])
  end

  it 'reads the branch again when an owner holds no target' do
    article = TrackedArticle.create!(title: 'Root')
    article.comments.create!(body: 'unreviewed')
    reviewer = TrackedAuthor.create!(name: 'Bea')
    article.comments.create!(body: 'reviewed', reviewer: reviewer)

    expect(refreshes { SpecTimelines.activity_timeline(article, **options) }).to eq(1)
  end
end
