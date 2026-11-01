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

# PT-AT reads a root's associations at the start of the transaction of the
# root version it reifies, so a window edge inside a transaction moves back to
# where the transaction began: the whole transaction is in the later window.
RSpec.describe 'Windows that meet inside a transaction',
               mutant_expression: 'PaperTrailDiff::ActivityTimelineBuilder' do
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

  def steps(article, within, method: :activity_timeline, group: nil)
    timeline(article, within, method, group).reject(&:empty?).map do |step|
      [step.sources.map(&:version_id), step.diff.attributes.keys, changed_keys(step)]
    end
  end

  def timeline(article, within, method, group)
    options = { within: within, associations: paths, group: group }
    return PaperTrailDiff.activity_timeline(article, **options) unless method == :analyze_many

    PaperTrailDiff.analyze_many([article], activity: true, **options).values.first.activity_timeline
  end

  def changed_keys(step)
    step.diff.associations['comments']&.changed&.map { |change| change.attributes.keys }
  end

  def window(article)
    article.versions.minimum(:created_at)..Time.now.utc
  end

  groups = [nil, :transaction]
  %i[activity_timeline analyze_many].each do |method|
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
    it 'starts where the transaction that crossed its start began' do
      article, child, root = comment_then_article
      within = root.created_at..Time.now.utc

      many = PaperTrailDiff.analyze_many([article], within: within, activity: true,
                                                    associations: paths).values.first
      one = PaperTrailDiff.analyze(article, within: within, activity: true, associations: paths)

      expect([many.window, one.window]).to all(eq(child.created_at..within.end))
    end

    it 'holds every step, and is the window asked for when no transaction crosses it' do
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
end
