# frozen_string_literal: true

require_relative '../support/association_database'

# `version_scope:` decides which changes activity reports on the root and its
# associations alike, from a replay of every version.
RSpec.describe 'version_scope: in activity on associations',
               mutant_expression: 'PaperTrailDiff::ActivityTimelineBuilder' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedComment.delete_all
    TrackedArticle.delete_all
  end

  let(:alice) { ->(versions) { versions.where(whodunnit: 'alice') } }
  let(:paths) { [:comments] }

  def by(person, &) = PaperTrail.request(whodunnit: person, &)

  # Alice and bob take turns; alice edits her comment after bob's last
  # version of the article, and bob created the article.
  def turns
    article = by('bob') { TrackedArticle.create!(title: 'Draft') }
    by('alice') { article.comments.create!(body: 'from alice') }
    theirs = by('bob') { article.comments.create!(body: 'from bob') }
    by('alice') { article.update!(title: 'Titled') }
    by('bob') { article.update!(title: 'Retitled') }
    by('alice') { article.comments.find_by!(body: 'from alice').update!(body: 'edited') }
    by('bob') { theirs.update!(body: 'edited by bob') }
    article.reload
  end

  def window(article)
    article.versions.minimum(:created_at)..Time.now.utc
  end

  # Each step's author and what it did to the title and the comments.
  def summary(steps)
    steps.reject(&:empty?).map do |step|
      [step.sources.map(&:whodunnit).uniq, step.diff.attributes['title']&.to_h,
       *comment_changes(step.diff.associations['comments'])]
    end
  end

  # The bodies added and removed, and how each changed comment's body did.
  def comment_changes(comments)
    return [nil, nil] unless comments

    [[comments.added, comments.removed].map { |records| bodies(records) },
     comments.changed.map { |change| change.attributes['body']&.to_h }]
  end

  def bodies(records)
    records.map { |record| record.attributes.fetch('body') }
  end

  def activity(article, method, **options)
    options = { associations: paths, **options }
    case method
    when :activity_timeline then PaperTrailDiff.activity_timeline(article, **options)
    when :analyze then PaperTrailDiff.analyze(article, activity: true, **options).activity_timeline
    else PaperTrailDiff.analyze_many([article], activity: true, **options).values.sole
                       .activity_timeline
    end
  end

  %i[activity_timeline analyze analyze_many].each do |method|
    it "reports the changes the filter keeps, each as the whole history shows it (#{method})" do
      article = turns
      within = window(article)
      every = summary(activity(article, method, within: within))

      kept = summary(activity(article, method, within: within, version_scope: alice))

      expect(kept).to eq(every.select { |authors, *| authors == ['alice'] })
      expect(kept.length).to eq(3)
      expect(kept.last).to eq([['alice'], nil, [[], []], [{ from: 'from alice', to: 'edited' }]])
    end
  end

  # The filter keeps no version of the root, which an explicit range would
  # otherwise read from its first kept one.
  it 'reports association changes from an explicit range whose root versions it all leaves out' do
    article = by('bob') { TrackedArticle.create!(title: 'Draft') }
    first = article.versions.first
    by('alice') { article.comments.create!(body: 'from alice') }
    by('bob') { article.update!(title: 'Titled') }

    steps = summary(activity(article, :activity_timeline, from: first, to: article,
                                                          version_scope: alice))

    expect(steps).to eq([[['alice'], nil, [['from alice'], []], []]])
  end

  # A `PaperTrail.request` block would restore the transaction PT-AT records
  # when it ends, so the author is assigned.
  it 'reports a transaction whole when the filter keeps any version saved in it' do
    article = by('bob') { TrackedArticle.create!(title: 'Draft') }
    begin
      TrackedArticle.transaction do
        PaperTrail.request.whodunnit = 'alice'
        article.comments.create!(body: 'from alice')
        PaperTrail.request.whodunnit = 'bob'
        article.update!(title: 'Titled')
      end
    ensure
      PaperTrail.request.whodunnit = nil
    end
    by('bob') { article.update!(title: 'Retitled') }
    within = window(article)

    grouped = summary(activity(article, :activity_timeline, within: within, group: :transaction,
                                                            version_scope: alice))

    expect(grouped).to eq([[%w[alice bob], { from: 'Draft', to: 'Titled' },
                            [['from alice'], []], []]])
  end

  it 'starts the analysis at the first change the filter keeps and ends it after the last' do
    article = turns

    analysis = PaperTrailDiff.analyze(article, within: window(article), activity: true,
                                               associations: paths, version_scope: alice)

    expect(bodies(analysis.from_snapshot.associations.fetch('comments').records)).to eq([])
    expect(bodies(analysis.to_snapshot.associations.fetch('comments').records))
      .to eq(['edited', 'from bob'])
    expect(analysis.to_snapshot.attributes.fetch('title')).to eq('Retitled')
    expect(analysis.timeline.map { |step| step.diff.attributes.fetch('title').to_h })
      .to eq([{ from: 'Draft', to: 'Titled' }])
  end

  # A range's last version opens no step, so a filter that keeps only that
  # version reports nothing, and neither does a range from a version to
  # itself.
  it 'reports an empty analysis when an explicit range reports no step' do
    article = by('bob') { TrackedArticle.create!(title: 'Draft') }
    by('bob') { article.update!(title: 'Titled') }
    by('alice') { article.update!(title: 'Retitled') }
    first, *, last = article.versions.reorder(:created_at, :id).to_a

    analyses = [{ associations: paths }, {}].flat_map do |options|
      [PaperTrailDiff.analyze(article, from: first, to: last, activity: true,
                                       version_scope: alice, **options),
       PaperTrailDiff.analyze(article, from: last, to: last, activity: true, **options)]
    end

    expect(analyses.map do |analysis|
      [analysis.activity_timeline, analysis.timeline, analysis.diff.empty?,
       analysis.from_snapshot, analysis.to_snapshot]
    end).to all(eq([[], [], true, nil, nil]))
  end

  it 'selects only the records the filter keeps a change of, which is all limit: counts' do
    start = Time.now.utc
    article = TrackedArticle.create!(title: 'Quiet')
    other = TrackedArticle.create!(title: 'Also quiet')
    by('alice') { article.comments.create!(body: 'from alice') }
    by('bob') { other.comments.create!(body: 'from bob') }
    options = { associations: paths, version_scope: alice }

    report = PaperTrailDiff.report(TrackedArticle, since: start, limit: 1, **options)
    scoped = PaperTrailDiff.analyze_scope(TrackedArticle, within: start..Time.now.utc, limit: 1,
                                                          activity: true, **options)

    expect([report.roots, scoped.roots]).to all(eq([article]))
    expect(summary(report.analyses.values.sole.activity_timeline))
      .to eq([[['alice'], nil, [['from alice'], []], []]])
  end

  # A batch over each record's whole history has no version after it to read
  # the root from, and used to refuse one whose versions the filter all left
  # out, while a single record reported nothing.
  it 'reports nothing for a filter that keeps no version, over a whole history in a batch' do
    article = TrackedArticle.create!(title: 'Draft')
    article.comments.create!(body: 'one')
    options = { activity: true, associations: paths, version_scope: :none.to_proc }

    analyses = [PaperTrailDiff.analyze(article, **options),
                PaperTrailDiff.analyze_many([article], **options).values.sole]

    expect(analyses.map(&:activity_timeline)).to eq([[], []])
    expect(analyses.map { |analysis| analysis.diff.empty? }).to eq([true, true])
  end

  # Each statement that reads the filter names the versions' author.
  it 'reads which transactions the filter keeps once for a batch, whatever its size' do
    start = Time.now.utc
    articles = Array.new(3) do |index|
      article = TrackedArticle.create!(title: "Article #{index}")
      by('alice') { article.comments.create!(body: "from alice #{index}") }
      article
    end
    within = start..Time.now.utc
    filtering = lambda do |records|
      count = 0
      callback = ->(*, payload) { count += 1 if payload[:sql].include?('whodunnit') }
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        PaperTrailDiff.analyze_many(records, within: within, activity: true, associations: paths,
                                             version_scope: alice)
      end
      count
    end

    expect(filtering.call(articles)).to eq(filtering.call(articles.first(1)))
  end

  describe 'without associations' do
    # Alice and bob take turns on the article alone; the last word is bob's.
    def retitled
      article = by('alice') { TrackedArticle.create!(title: 'Draft') }
      %w[bob alice bob].each_with_index do |person, index|
        by(person) { article.update!(title: "Title #{index}") }
      end
      article.reload
    end

    def diffs(steps)
      steps.map { |step| step.diff.to_h }
    end

    it 'reports the root versions it keeps, as timeline does' do
      article = retitled
      ranges = [{ within: window(article) }, { from: article.versions.first, to: article },
                { from: article.versions.first, to: article.versions.last }]

      ranges.each do |range|
        steps = PaperTrailDiff.activity_timeline(article, **range, version_scope: alice)
        timeline = PaperTrailDiff.timeline(article, **range, version_scope: alice)

        expect(diffs(steps)).to eq(diffs(timeline))
        expect(steps.map { |step| step.source_boundary.whodunnit }).to eq(%w[alice alice])
      end
    end

    # Each root version shows its own change, so a transaction alice and bob
    # both saved the article in is not reported whole.
    it 'reports the versions it keeps of a transaction it does not keep all of' do
      article = by('bob') { TrackedArticle.create!(title: 'Draft') }
      begin
        TrackedArticle.transaction do
          PaperTrail.request.whodunnit = 'alice'
          article.update!(title: 'Titled')
          PaperTrail.request.whodunnit = 'bob'
          article.update!(title: 'Retitled')
        end
      ensure
        PaperTrail.request.whodunnit = nil
      end

      steps = PaperTrailDiff.activity_timeline(article, within: window(article),
                                                        version_scope: alice)

      expect(steps.map { |step| step.diff.attributes.fetch('title').to_h })
        .to eq([{ from: 'Draft', to: 'Titled' }])
    end

    it 'reports nothing when it keeps no version, from either kind of range' do
      article = retitled
      first = article.versions.first
      none = :none.to_proc

      readings = [
        PaperTrailDiff.activity_timeline(article, from: first, to: article, version_scope: none),
        PaperTrailDiff.activity_timeline(article, from: first, to: article.versions.last,
                                                  version_scope: none)
      ]
      analysis = PaperTrailDiff.analyze(article, from: first, to: article.versions.last,
                                                 activity: true, version_scope: none)

      expect(readings).to eq([[], []])
      expect([analysis.activity_timeline, analysis.timeline, analysis.diff.empty?])
        .to eq([[], [], true])
    end
  end
end
