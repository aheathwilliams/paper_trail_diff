# frozen_string_literal: true

require_relative '../support/association_database'

# A transaction of associated records that crosses a window's edge has its
# changes in one window (see the reference's time windows). The window before
# the edge leaves them to the later one when a version saved after the edge is
# of a record that was on the requested paths before the transaction. Here
# the only such record is a reply whose comment the transaction moved away
# before the edge, so the later window finds neither by reading from its
# start: the comment has left, and the reply hangs under it.
RSpec.describe 'A window edge inside a transaction that detached a record before it' do
  let(:article) { TrackedArticle.create!(title: 'First') }
  let(:other) { TrackedArticle.create!(title: 'Other') }
  let(:comment) { article.comments.create!(body: 'moved') }
  let(:reply) { comment.replies.create!(body: 'under it') }
  let(:paths) { { comments: :replies } }

  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedReply, TrackedComment, TrackedArticle].each(&:delete_all)
    reply
    other
  end

  # The comment's move, then whatever the block saves.
  def crossing
    TrackedArticle.transaction do
      comment.update!(article: other)
      yield
    end
    article.update!(title: 'Second')
  end

  def edge
    PaperTrail::Version.where(item_type: 'TrackedReply').order(:id).last.created_at
  end

  def removed(within, method)
    timeline(within, method).flat_map do |step|
      comments = step.diff.associations['comments']
      comments ? comments.removed.map { |record| record.attributes.fetch('body') } : []
    end
  end

  def timeline(within, method)
    options = { within: within, associations: paths }
    return PaperTrailDiff.activity_timeline(article.reload, **options) if method == :single

    PaperTrailDiff.analyze_many([article.reload], activity: true, **options)
                  .values.first.activity_timeline
  end

  %i[single batch].each do |method|
    context "when read #{method}" do
      it 'reports the move in the later window when the transaction then destroyed the reply' do
        crossing { reply.destroy! }
        start = article.versions.minimum(:created_at)

        expect(removed(start...edge, method)).to eq([])
        expect(removed(edge.., method)).to eq(['moved'])
      end

      it 'reports the move in the later window when the transaction then edited the reply' do
        crossing { reply.update!(body: 'edited') }
        start = article.versions.minimum(:created_at)

        expect(removed(start...edge, method)).to eq([])
        expect(removed(edge.., method)).to eq(['moved'])
      end
    end
  end

  it 'selects the article for a report since the edge' do
    crossing { reply.destroy! }

    report = PaperTrailDiff.report(TrackedArticle.where(id: article.id), since: edge, limit: 5,
                                                                         associations: paths)

    expect(report.analyses.values.sole.diff.associations.fetch('comments').removed.length).to eq(1)
  end
end
