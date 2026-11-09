# frozen_string_literal: true

require_relative '../support/association_database'

# A window edge inside a transaction moves back to where it began (see
# TransactionCut). An edge is an instant, though, and where the versions
# column keeps whole seconds, or the clock that dated them stood still, a
# transaction can begin at the instant the one before it saved its last
# versions. The edge moved there would cut that earlier transaction in two.
RSpec.describe 'A window edge moved to an instant another transaction ends at' do
  let(:base) { Time.utc(2026, 3, 1, 12) }
  let(:article) { TrackedArticle.create!(title: 'First') }
  let(:comment) { article.comments.create!(body: 'before') }
  let(:paths) { [:comments] }

  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedReply, TrackedComment, TrackedArticle].each(&:delete_all)
    comment
    stamp(PaperTrail::Version.order(:id).to_a, [base, base])
    edit_then_retitle
    retitle_then_add
  end

  # Saves the versions of a block, in order, at `times`.
  def saved(times)
    last = PaperTrail::Version.maximum(:id)
    TrackedArticle.transaction { yield }
    stamp(PaperTrail::Version.where(id: (last + 1)..).order(:id).to_a, times)
  end

  def stamp(versions, times)
    versions.zip(times) do |version, time|
      PaperTrail::Version.where(id: version.id).update_all(created_at: time)
    end
  end

  # The comment at 10 s, then the article at 20 s.
  def edit_then_retitle
    saved([base + 10, base + 20]) do
      comment.update!(body: 'after')
      article.update!(title: 'Second')
    end
  end

  # The article at 20 s, where the transaction before it ended, then a new
  # comment at 30 s.
  def retitle_then_add
    saved([base + 20, base + 30]) do
      article.update!(title: 'Third')
      article.comments.create!(body: 'new')
    end
  end

  # What each step that changed something changed.
  def changes(within, method)
    timeline(within, method).reject(&:empty?).map do |step|
      comments = step.diff.associations['comments']
      [*step.diff.attributes.slice('title').map { |_, change| change.to_h.fetch(:to) },
       *comments&.changed&.map { |change| change.attributes.fetch('body').to_h.fetch(:to) },
       *comments&.added&.map { |record| record.attributes.fetch('body') }]
    end
  end

  def timeline(within, method)
    options = { within: within, associations: paths, activity: true }
    return PaperTrailDiff.analyze(article.reload, **options).activity_timeline if method == :single

    PaperTrailDiff.analyze_many([article.reload], **options).values.first.activity_timeline
  end

  %i[single batch].each do |method|
    context "read #{method}" do
      # The edge is inside the second transaction, which began at 20 s, the
      # instant the first saved the article. Cut there, the first
      # transaction's comment edit would surface in the second's step.
      it 'reports each transaction whole, in the later window' do
        edge = base + 25
        whole = changes((base + 5).., method)

        expect(changes((base + 5)...edge, method) + changes(edge.., method)).to eq(whole)
        expect(changes(edge.., method)).to eq(whole)
      end

      it 'moves the later window to where the earlier transaction began' do
        analysis = PaperTrailDiff.analyze_many([article.reload], within: (base + 25).., activity: true,
                                                                 associations: paths).values.first

        expect(analysis.window.begin).to eq(base + 10)
      end
    end
  end
end
