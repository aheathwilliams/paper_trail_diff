# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :window_articles, force: true do |table|
    table.string :title, null: false
    table.timestamps null: false
  end

  create_table :window_comments, force: true do |table|
    table.integer :article_id, null: false
    table.string :body, null: false
    table.timestamps null: false
  end
end

class WindowArticle < ActiveRecord::Base
  has_many :comments, class_name: 'WindowComment', foreign_key: :article_id, inverse_of: :article
  has_paper_trail
end

class WindowComment < ActiveRecord::Base
  belongs_to :article, class_name: 'WindowArticle', inverse_of: :comments
  has_paper_trail
end

# A transaction takes effect where it saved its last version (see
# TransactionEnds), so one with a window edge inside it is wholly in the later
# window, which reads it from where it began.
RSpec.describe 'Windows that meet inside a transaction',
               mutant_expression: %w[PaperTrailDiff::ActivityTimelineBuilder
                                     PaperTrailDiff::TimelineRange
                                     PaperTrailDiff::TransactionEnds
                                     PaperTrailDiff::RecordedTransactionEnds
                                     PaperTrailDiff::CrossingTransactions
                                     PaperTrailDiff::TransactionCut
                                     PaperTrailDiff::TimeVersionRange
                                     PaperTrailDiff::ActivityVersionCollector
                                     PaperTrailDiff::ActivityTreeFilter
                                     PaperTrailDiff::BatchedRootAnalyses
                                     PaperTrailDiff::PreparedHistoryLoader
                                     PaperTrailDiff::RootVersionSelection] do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    WindowComment.delete_all
    WindowArticle.delete_all
  end

  let(:paths) { [:comments] }

  def article_with_comment
    article = WindowArticle.create!(title: 'First')
    comment = article.comments.create!(body: 'before')
    [article, comment]
  end

  # As `touch: true` saves them: the comment's version, then the article's.
  def comment_then_article
    article, comment = article_with_comment
    WindowArticle.transaction do
      comment.update!(body: 'after')
      article.update!(title: 'Second')
    end
    article.update!(title: 'Third')
    [article.reload, comment.versions.last, article.versions.where(event: 'update').first]
  end

  def article_then_comment
    article, comment = article_with_comment
    WindowArticle.transaction do
      article.update!(title: 'Second')
      comment.update!(body: 'after')
    end
    article.update!(title: 'Third')
    [article.reload, article.versions.where(event: 'update').first, comment.versions.last]
  end

  # A transaction that saves no version of the root: the comment's update,
  # then a new comment.
  def comments_only
    article, comment = article_with_comment
    WindowArticle.transaction do
      comment.update!(body: 'after')
      article.comments.create!(body: 'new')
    end
    article.update!(title: 'Second')
    [article.reload, comment.versions.last, WindowComment.find_by!(body: 'new').versions.first]
  end

  def steps(article, within, method: :analyze, group: nil)
    timeline(article, within, method, group).reject(&:empty?).map do |step|
      [step.sources.map(&:version_id), step.diff.attributes.keys, changed_keys(step)]
    end
  end

  def timeline(article, within, method, group)
    options = { within: within, associations: paths, group: group }
    return SpecTimelines.activity_timeline(article, **options) unless method == :analyze_many

    PaperTrailDiff.analyze_many([article], activity: true, **options).values.first.activity_timeline
  end

  def changed_keys(step)
    step.diff.associations['comments']&.changed&.map { |change| change.attributes.keys }
  end

  # The bodies of the comments each step adds and removes.
  def bodies(article, within, method, group)
    timeline(article, within, method, group).reject(&:empty?).map do |step|
      comments = step.diff.associations['comments']
      comments && [comments.added, comments.removed].map do |records|
        records.map { |record| record.attributes.fetch('body') }
      end
    end
  end

  def window(article)
    article.versions.minimum(:created_at)..Time.now.utc
  end

  groups = [nil, :transaction]
  %i[analyze analyze_many].each do |method|
    groups.each do |group|
      context "with #{method} (group: #{group.inspect})" do
        it 'reports a transaction split by the edge in the later window' do
          article, child, root = comment_then_article
          whole = window(article)
          left = steps(article, whole.begin...root.created_at, method: method, group: group)
          right = steps(article, root.created_at..whole.end, method: method, group: group)

          expect(left + right).to eq(steps(article, whole, method: method, group: group))
          expect(right.first).to include([['body']])
          expect(right.first.first).to include(root.id)
          expect(left.flatten).not_to include(child.id)
        end

        # Each record in it reads as it was before it began, here and in a
        # window ending inside it, so the part saved before the edge is in
        # the later window.
        it 'reports a transaction of children split by the edge in the later window' do
          article, before_edge, at_edge = comments_only
          whole = window(article)
          by_transaction = lambda do |within|
            steps(article, within, method: method, group: group).map do |sources, *diff|
              [PaperTrail::Version.where(id: sources).distinct.pluck(:transaction_id), *diff]
            end
          end
          left = by_transaction.call(whole.begin...at_edge.created_at)
          right = by_transaction.call(at_edge.created_at..whole.end)

          expect(left + right).to eq(by_transaction.call(whole))
          expect(right.first).to eq([[at_edge.transaction_id], [], [['body']]])
          expect(left.flatten).not_to include(before_edge.transaction_id)
        end

        # The comment it destroyed before the edge has no live row and no
        # version after the edge, so only history read from where the
        # transaction began holds it.
        it 'reports a record such a transaction destroyed before the edge in the later window' do
          article, comment = article_with_comment
          added = WindowArticle.transaction do
            comment.destroy!
            article.comments.create!(body: 'new')
          end
          article.update!(title: 'Second')
          whole = window(article)
          edge = added.versions.first.created_at
          read = ->(within) { bodies(article, within, method, group) }

          expect(read.call(whole.begin...edge) + read.call(edge..whole.end)).to eq(read.call(whole))
          expect(read.call(edge..whole.end).first).to eq([['new'], ['before']])
        end

        # The comment it edited after the edge was on another article then,
        # and moves to this one later. That edit is still where the
        # transaction ends, so the later window reports what it destroyed.
        it 'reports such a transaction in the later window, though what it saved after ' \
           'the edge was outside the tree' do
          article, comment = article_with_comment
          elsewhere = WindowArticle.create!(title: 'Other').comments.create!(body: 'elsewhere')
          WindowArticle.transaction do
            comment.destroy!
            elsewhere.update!(body: 'edited')
          end
          elsewhere.update!(article: article)
          article.update!(title: 'Second')
          whole = window(article)
          edge = elsewhere.versions.where(event: 'update').first.created_at
          read = ->(within) { bodies(article, within, method, group) }
          later = PaperTrailDiff.analyze_many([article], within: edge..whole.end, activity: true,
                                                         associations: paths, group: group)

          expect(read.call(whole.begin...edge) + read.call(edge..whole.end)).to eq(read.call(whole))
          expect(read.call(edge..whole.end).first).to eq([[], ['before']])
          expect(later.values.first.diff.associations.fetch('comments').removed.map do |record|
            record.attributes.fetch('body')
          end).to eq(['before'])
        end

        it 'does so when the root saved first' do
          article, root, child = article_then_comment
          whole = window(article)
          left = steps(article, whole.begin...child.created_at, method: method, group: group)
          right = steps(article, child.created_at..whole.end, method: method, group: group)

          expect(left + right).to eq(steps(article, whole, method: method, group: group))
          expect(left.flatten).not_to include(root.id)
          expect(right.first).to include(['title'])
        end
      end
    end
  end

  describe 'the window an analysis covers' do
    it 'is the window asked for, though it reports a transaction that began before it' do
      article, _child, root = comment_then_article
      within = root.created_at..Time.now.utc

      many = PaperTrailDiff.analyze_many([article], within: within, activity: true,
                                                    associations: paths).values.first
      one = PaperTrailDiff.analyze(article, within: within, activity: true, associations: paths)

      expect([many.window, one.window]).to all(eq(within))
    end

    it 'holds every step when no transaction crosses it' do
      article, = comment_then_article
      within = window(article)

      analyses = [
        PaperTrailDiff.analyze(article, within: within),
        PaperTrailDiff.analyze_many([article], within: within, activity: true,
                                               associations: paths).values.first
      ]

      expect(analyses.map(&:window)).to all(eq(within))
      expect(analyses.last.activity_timeline.map { |step| step.source_boundary.recorded_at })
        .to all(satisfy { |time| within.cover?(time) })
    end

    it 'is nothing without a window' do
      article, = comment_then_article

      expect(PaperTrailDiff.analyze(article).window).to be_nil
      expect(PaperTrailDiff.analyze_many([article], within: nil).values.first.window).to be_nil
    end
  end

  it 'ends a window at an inclusive end inside a transaction before the transaction' do
    article, child, root = comment_then_article
    whole = window(article)

    steps = steps(article, whole.begin..child.created_at)

    expect(steps.flatten).not_to include(child.id, root.id)
  end

  it 'closes a window read again from where such a transaction began when it read the row' do
    article, _child, root = comment_then_article

    closing = SpecTimelines.activity_timeline(article, within: root.created_at..,
                                                       associations: paths).last.to_boundary

    expect(closing.kind).to eq(:current)
    expect(closing.recorded_at).to be_within(60).of(Time.now.utc)
  end

  # Read again from where it began, the history does not ask again.
  it 'asks once how far back a transaction open at the start reaches' do
    article, _child, root = comment_then_article
    allow(PaperTrailDiff::CrossingTransactions).to receive(:reach).and_call_original

    steps(article, root.created_at..Time.now.utc)

    expect(PaperTrailDiff::CrossingTransactions).to have_received(:reach).once
  end

  it 'reports nothing of a transaction that a window lies inside' do
    article, child, root = comment_then_article

    expect(steps(article, child.created_at..(root.created_at - Rational(1, 1_000_000)))).to eq([])
  end

  it 'reports the change the transaction made before the edge in a report since the edge' do
    article, child, root = comment_then_article

    report = PaperTrailDiff.report(WindowArticle.all, since: root.created_at, limit: 5,
                                                      associations: paths, group: :transaction)
    first = report.analyses.fetch(PaperTrailDiff::Endpoint.identity(article))
                  .activity_timeline.reject(&:empty?).first

    expect(first.sources.map(&:version_id)).to eq([child.id, root.id])
    expect(changed_keys(first)).to eq([['body']])
  end

  # Activity reports the transaction where it ends, in the later window, which
  # selects the root by the comment saved there. A comparison of the root's
  # own versions reports each where it was saved, in the earlier window.
  it 'selects a root saved before the edge in a transaction that saved its paths after it' do
    article, comment = article_with_comment
    start = Time.now.utc
    WindowArticle.transaction do
      article.update!(title: 'Second')
      comment.update!(body: 'after')
    end
    edge = comment.versions.last.created_at
    titles = lambda do |within, activity|
      analyses = PaperTrailDiff.analyze_scope(WindowArticle.all, within: within, limit: 5,
                                                                 associations: paths,
                                                                 activity: activity).analyses
      analyses.transform_values { |analysis| analysis.diff.attributes['title']&.to_h }
    end
    key = PaperTrailDiff::Endpoint.identity(article)

    change = { key => { from: 'First', to: 'Second' } }
    expect([false, true].map { |activity| titles.call(edge..Time.now.utc, activity) })
      .to eq([{}, change])
    expect([false, true].map { |activity| titles.call(start...edge, activity) })
      .to eq([change, { key => nil }])
  end

  # A historical filter reads what a root held by when its versions were
  # saved, so in the later window this one held only its new title.
  it 'filters a root reported in the later window by what its versions held there' do
    article, comment = article_with_comment
    WindowArticle.transaction do
      article.update!(title: 'Second')
      comment.update!(body: 'after')
    end
    edge = comment.versions.last.created_at
    selected = lambda do |title|
      PaperTrailDiff.analyze_scope(WindowArticle.all, within: edge..Time.now.utc, limit: 5,
                                                      associations: paths, activity: true,
                                                      historical_filter: { title: title })
                    .analyses.keys
    end
    key = PaperTrailDiff::Endpoint.identity(article)

    expect(%w[First Second Third].map(&selected)).to eq([[], [key], []])
  end

  # Two roots saved in one transaction, one before the edge and one after it.
  # A report selects a record by its versions inside its window, so each
  # root's change is in the window its version is in. Moved into the later
  # window, the first root's change was in neither report.
  def split_across_roots
    first, second = %w[one two].map { |title| WindowArticle.create!(title: title) }
    start = Time.now.utc
    edge = WindowArticle.transaction do
      yield second
      Time.now.utc.tap { first.update!(title: 'one edited') }
    end
    [first, second, start, edge]
  end

  it 'reports a root saved before the edge, in a transaction another root saved after it' do
    first, second, start, edge = split_across_roots { |root| root.update!(title: 'two edited') }
    titles = lambda do |result|
      result.analyses.transform_values { |analysis| analysis.diff.attributes['title']&.to_h }
            .compact
    end

    earlier = PaperTrailDiff.analyze_scope(WindowArticle.all, within: start...edge, limit: 5,
                                                              activity: true)
    later = PaperTrailDiff.report(WindowArticle.all, since: edge, limit: 5)

    expect([titles.call(earlier), titles.call(later)])
      .to eq([{ ['WindowArticle', second.id.to_s] => { from: 'two', to: 'two edited' } },
              { ['WindowArticle', first.id.to_s] => { from: 'one', to: 'one edited' } }])
  end

  it 'reports a root destroyed before the edge, in a transaction another root saved after it' do
    _, second, start, edge = split_across_roots(&:destroy!)
    removed = lambda do |result|
      result.deleted.transform_values do |analysis|
        analysis.activity_timeline.last.diff.record_presence_change.from.attributes['title']
      end
    end

    earlier = PaperTrailDiff.analyze_scope(WindowArticle.all, within: start...edge, limit: 5,
                                                              activity: true, include_deleted: true)
    later = PaperTrailDiff.report(WindowArticle.all, since: edge, limit: 5, include_deleted: true)

    expect([removed.call(earlier), removed.call(later)])
      .to eq([{ ['WindowArticle', second.id.to_s] => 'two' }, {}])
  end
end
