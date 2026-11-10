# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/recorded_changes_database'

# Which event each change row names: the version of its record that made the
# change, and, with recorded changes read, an unversioned source for what was
# saved without a version. See ChangeAttribution.
RSpec.describe 'Change row sources',
               mutant_expression: %w[PaperTrailDiff::ActivityHistoryBuilder
                                     PaperTrailDiff::ActivityTransactionGrouper
                                     PaperTrailDiff::ActivityTimelineBuilder] do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    RecordedVersion.delete_all
    ActiveRecord::Base.connection.execute('DELETE FROM tracked_articles_tags')
    [TrackedReply, TrackedComment, TrackedArticle, TrackedAuthor, RecordedNote].each(&:delete_all)
  end

  # Each row as its record, field, values, and the version it names:
  # `:unversioned` for a change saved without one.
  def table(rows)
    rows.map do |row|
      source = row.unversioned? ? :unversioned : row.source.version_id
      [row.change, row.record&.id, row.attribute, row.from, row.to, source]
    end
  end

  def version_of(record)
    record.versions.reorder(:created_at, :id).last.id
  end

  def rows(article, **options)
    PaperTrailDiff.activity_timeline(
      article, from: article.versions.reorder(:created_at, :id).first,
               associations: [:comments], **options
    ).flat_map(&:change_rows)
  end

  # The rows of edited fields.
  def edits(rows)
    rows.select { |row| row.change == :changed }
  end

  describe 'crediting' do
    let!(:history) do
      article = TrackedArticle.create!(title: 'A')
      first = article.comments.create!(body: 'one')
      second = article.comments.create!(body: 'two')
      TrackedArticle.transaction do
        article.update!(title: 'B')
        first.update!(body: 'one!')
        second.update!(body: 'two!')
        first.update!(reviewer_id: 4)
      end
      { article: article, first: first, second: second }
    end

    def sorted(rows)
      table(edits(rows)).sort_by { |row| [row[1].to_i, row[2]] }
    end

    # Inside the transaction each child's change surfaces at its last event,
    # in a step whose source is another record's version. Which of a record's
    # versions made a change takes what they recorded; without it, the change
    # is credited to the last of them.
    it "credits each change to its record's version, whether grouped or not" do
      article, first, second = history.values_at(:article, :first, :second)
      body, reviewer = first.versions.reorder(:created_at, :id).last(2).map(&:id)
      recorded = [[:changed, nil, 'title', 'A', 'B', version_of(article)],
                  [:changed, first.id, 'body', 'one', 'one!', body],
                  [:changed, first.id, 'reviewer_id', nil, 4, reviewer],
                  [:changed, second.id, 'body', 'two', 'two!', version_of(second)]]
      unread = recorded.map do |row|
        row[1] == first.id && row[2] == 'body' ? row[0..4] + [reviewer] : row
      end

      [{}, { group: :transaction }].each do |options|
        expect(sorted(rows(article, **options))).to eq(unread)
        expect(sorted(rows(article, recorded_changes: true, **options))).to eq(recorded)
      end
    end

    it 'credits a created or destroyed record and its fields to its own create or destroy' do
      article = history.fetch(:article)
      created = nil
      TrackedArticle.transaction do
        article.update!(title: 'C')
        created = article.comments.create!(body: 'new')
        history.fetch(:second).destroy!
      end
      steps = PaperTrailDiff.activity_timeline(
        article, from: article.versions.reorder(:id).last, associations: [:comments],
                 group: :transaction
      )
      sources = steps.first.change_rows.to_h do |row|
        [[row.change, row.record&.id, row.attribute], row.source.event]
      end

      expect(sources).to include([:added, created.id, nil] => 'create',
                                 [:added, created.id, 'body'] => 'create',
                                 [:removed, history.fetch(:second).id, nil] => 'destroy',
                                 [:removed, history.fetch(:second).id, 'body'] => 'destroy',
                                 [:changed, nil, 'title'] => 'update')
    end
  end

  describe 'a change saved without a version' do
    it 'splits it from the change before it, and credits it to no version' do
      article = TrackedArticle.create!(title: 'A')
      article.update!(title: 'B')
      article.update_columns(title: 'Z', author_id: 7)
      update = version_of(article)

      expect(table(edits(rows(article, recorded_changes: true))))
        .to eq([[:changed, nil, 'author_id', nil, 7, :unversioned],
                [:changed, nil, 'title', 'A', 'B', update],
                [:changed, nil, 'title', 'B', 'Z', :unversioned]])
      expect(table(edits(rows(article))))
        .to eq([[:changed, nil, 'author_id', nil, 7, update],
                [:changed, nil, 'title', 'A', 'Z', update]])
    end

    it "splits a child's write after its create from the values its create recorded" do
      article = TrackedArticle.create!(title: 'A')
      comment = article.comments.create!(body: 'recorded')
      comment.update_columns(body: 'written later')

      added = table(rows(article, recorded_changes: true)).select { |row| row[1] == comment.id }

      expect(added.map { |row| row.values_at(0, 2, 3, 4, 5) }).to include(
        [:added, nil, nil, nil, version_of(comment)],
        [:added, 'body', nil, 'recorded', version_of(comment)],
        [:changed, 'body', 'recorded', 'written later', :unversioned]
      )
    end

    it 'leaves a change whole where its versions cannot show it was unrecorded' do
      article = TrackedArticle.create!(title: 'A')
      article.touch
      article.update_columns(title: 'Z')
      note = RecordedNote.create!(title: 'n', rank: 1)
      RankIgnoringNote.find(note.id).update!(title: 'm', rank: 2)
      touched = version_of(article)

      expect(table(edits(rows(article, recorded_changes: true))))
        .to eq([[:changed, nil, 'title', 'A', 'Z', touched]])
      ignored = PaperTrailDiff.activity_timeline(RankIgnoringNote.find(note.id),
                                                 recorded_changes: true).flat_map(&:change_rows)
      expect(table(edits(ignored)).map { |row| row.values_at(2, 3, 4) })
        .to eq([['rank', 1, 2], %w[title n m]])
      expect(ignored).not_to include(be_unversioned)
    end

    it 'credits a change before a window to its own version when its transaction ends inside' do
      article = TrackedArticle.create!(title: 'A')
      comment = article.comments.create!(body: 'one')
      start = nil
      TrackedArticle.transaction do
        comment.update!(body: 'two')
        start = Time.now.utc
        comment.update!(reviewer_id: 3)
      end

      rows = PaperTrailDiff.activity_timeline(
        article, within: start.., associations: [:comments], recorded_changes: true
      ).flat_map(&:change_rows)

      expect(table(edits(rows)).map { |row| row.values_at(2, 3, 4, 5) })
        .to eq([['body', 'one', 'two', comment.versions.reorder(:created_at, :id)[-2].id],
                ['reviewer_id', nil, 3, version_of(comment)]])
    end

    # A version class without `transaction_id` saves each version alone. A
    # comment that rejoins the article keeps the state it left with, which a
    # step before already reported, so its rows come from the save that
    # moved it back, and none from its earlier create.
    it 'reads each version saved outside a transaction on its own' do
      allow(PaperTrailDiff::VersionBoundary).to receive(:transaction_id).and_return(nil)
      article = TrackedArticle.create!(title: 'A')
      comment = article.comments.create!(body: 'recorded')
      comment.update_columns(body: 'written')
      comment.update!(article_id: TrackedArticle.create!(title: 'O').id)
      article.update!(title: 'B')
      article.update_columns(author_id: 9)
      comment.update!(article_id: article.id)

      steps = PaperTrailDiff.activity_timeline(
        article, from: article.versions.reorder(:created_at, :id).first,
                 associations: [:comments], recorded_changes: true
      )

      expect(table(steps[1].change_rows)).to include(
        [:changed, comment.id, 'body', 'recorded', 'written', :unversioned]
      )
      expect(table(edits(steps[3].change_rows)))
        .to eq([[:changed, nil, 'author_id', nil, 9, :unversioned],
                [:changed, nil, 'title', 'A', 'B', version_of(article)]])
      expect(table(steps.last.change_rows).map(&:last).uniq).to eq([version_of(comment)])
    end

    it 'reads the same in a batch, a report, and with a version filter' do
      article = TrackedArticle.create!(title: 'A')
      start = Time.now.utc
      PaperTrail.request(whodunnit: 'alice') { article.update!(title: 'B') }
      article.update_columns(title: 'Z')
      expected = [[:changed, nil, 'title', 'A', 'B', version_of(article)],
                  [:changed, nil, 'title', 'B', 'Z', :unversioned]]
      options = { associations: [:comments], recorded_changes: true }
      alice = ->(versions) { versions.where(whodunnit: 'alice') }

      batch = PaperTrailDiff.analyze_many([article], within: start.., activity: true, **options)
      report = PaperTrailDiff.report(TrackedArticle.all, since: start, limit: 5, **options)
      filtered = PaperTrailDiff.analyze(article, within: start.., activity: true,
                                                 version_scope: alice, **options)

      [batch.values.first, report.analyses.values.first, filtered].each do |analysis|
        expect(table(edits(analysis.change_rows))).to eq(expected)
      end
    end
  end
end
