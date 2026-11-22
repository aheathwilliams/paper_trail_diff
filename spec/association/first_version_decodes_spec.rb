# frozen_string_literal: true

require_relative '../support/association_database'

# Rows from before PaperTrail have no version until they are next saved, and
# only that version's stored state names the owner they held before it. A
# window long past once decoded the first version of every child in the
# table saved since, to find the few under the owners asked for: one order
# among 200,000 line items took 12 s, and a page of a report 14 s. Every spec
# passed, since none held more than a handful of such rows. These count the
# stored states decoded, which grow with the table where the work does not.
RSpec.describe 'Stored states read for first versions' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedReply, TrackedComment, TrackedArticle, TrackedAuthor].each(&:delete_all)
  end

  # Each stored state decoded, by its record's id, or nil for a version read
  # with its state alone.
  let(:decoded) { [] }

  def counting_decodes
    allow_any_instance_of(PaperTrail::Version).to receive(:object_deserialized)
      .and_wrap_original do |original|
        decoded << original.receiver.attributes['item_id']
        original.call
      end
    yield
  end

  def legacy(&)
    PaperTrail.request(enabled: false, &)
  end

  # Ten articles of three legacy comments each, the first reviewed by an
  # author renamed in the window. After it, every comment is saved without
  # changing its article, and one more is moved off the first article.
  def legacy_tree
    reviewer = TrackedAuthor.create!(name: 'Reviewer')
    articles = Array.new(10) { |index| legacy { TrackedArticle.create!(title: "A#{index}") } }
    comments = articles.flat_map do |article|
      Array.new(3) { |index| legacy { article.comments.create!(body: index.to_s) } }
    end
    legacy { comments.first.update!(reviewer: reviewer) }
    moved = legacy { articles.first.comments.create!(body: 'moved') }
    start = Time.now.utc
    reviewer.update!(name: 'Renamed')
    window = start..Time.now.utc
    comments.each { |comment| comment.update!(body: 'edited') }
    moved.update!(article: articles.last)
    [articles, moved, window]
  end

  # The first article's own comments, the moved one, and the reviewer, whose
  # states the analysis reads to build its snapshots.
  def own_records(articles, moved)
    TrackedComment.where(article_id: articles.first.id).ids + [moved.id] + TrackedAuthor.ids
  end

  it 'decodes for one owner only first versions that may have changed the key' do
    articles, moved, window = legacy_tree

    analysis = counting_decodes do
      PaperTrailDiff.analyze(articles.first, within: window, associations: ['comments.reviewer'],
                                             activity: true)
    end

    expect(analysis.activity_timeline.count { |step| !step.empty? }).to eq(1)
    expect(decoded).to include(moved.id)
    expect(decoded.uniq - own_records(articles, moved)).to eq([])
  end

  it 'decodes for a report only first versions that may have changed the key' do
    articles, moved, window = legacy_tree

    report = counting_decodes do
      PaperTrailDiff.report(TrackedArticle.all, within: window, associations: ['comments.reviewer'],
                                                limit: 25)
    end

    expect(report.roots).to eq([articles.first])
    expect(decoded).to include(moved.id)
    expect(decoded.uniq - own_records(articles, moved)).to eq([])
  end
end
