# frozen_string_literal: true

require_relative '../support/association_database'

# `analyze` and `analyze_many` read one record's window, or its whole
# history, the same way: a batch shares one history between its roots, which
# starts before and runs on past the versions one root replays, and neither
# that nor what else a batch reads changes what a root reports.
RSpec.describe 'A record read alone and in a batch' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedReply, TrackedComment, TrackedArticle, TrackedAuthor].each(&:delete_all)
  end

  # Saves the block's versions as part of transaction `id`, as if they were
  # saved while other transactions were open. The number is one no version of
  # the suite takes as its id.
  def in_transaction(id, whodunnit, &)
    saved = PaperTrail::Version.maximum(:id) || 0
    PaperTrail.request(whodunnit: whodunnit, &)
    PaperTrail::Version.where('id > ?', saved).update_all(transaction_id: 1_000_000 + id)
  end

  def key(record) = ['TrackedArticle', record.id.to_s]

  def rows(analysis)
    analysis.change_rows.map do |row|
      [row.change, row.association_path.join('.'), row.attribute, row.from, row.to,
       row.source.whodunnit]
    end
  end

  def titles(analysis)
    analysis.timeline.map { |step| step.diff.to_h.fetch(:attributes).fetch('title').values }
  end

  # The change each step reports to the body of the article's comment.
  def bodies(analysis)
    analysis.timeline.map do |step|
      step.diff.to_h.dig(:associations, 'comments', :changed, 0, :attributes, 'body')&.values
    end
  end

  # Each step as its boundaries' versions and its diff. A boundary at the
  # current record carries when it was read, which differs between reads.
  def steps(timeline)
    timeline.map do |step|
      [step.from_boundary.version_id, step.to_boundary.kind, step.to_boundary.version_id,
       step.diff.to_h]
    end
  end

  def both(article, others = [], **options)
    single = PaperTrailDiff.analyze(article.reload, **options)
    batch = PaperTrailDiff.analyze_many([article, *others], **options).fetch(key(article))
    [single, batch]
  end

  describe 'with activity' do
    let(:options) { { associations: %i[comments author], activity: true } }

    # X saves the article after the window and goes on; U renames its author
    # before X ends. The other article closes on its current row, so the
    # batch's history runs through U's version, which the first article's
    # timeline does not hold.
    it 'does not report a change another transaction made after the window' do
      ann = TrackedAuthor.create!(name: 'Ann')
      bob = TrackedAuthor.create!(name: 'Bob')
      article = TrackedArticle.create!(title: 'one', author: ann)
      other = TrackedArticle.create!(title: 'other')
      first = article.comments.create!(body: 'first')
      second = article.comments.create!(body: 'second')
      start = Time.now
      in_transaction(1, 'P') { first.update!(body: 'first edited') }
      in_transaction(2, 'Q') { second.update!(body: 'second edited') }
      in_transaction(1, 'P') { article.update!(author: bob) }
      finish = Time.now
      in_transaction(3, 'X') { article.update!(title: 'three') }
      in_transaction(4, 'U') { bob.update!(name: 'Robert') }
      in_transaction(3, 'X') { TrackedAuthor.create!(name: 'X goes on') }

      single, batch = both(article, [other], within: start...finish, **options)
      later = PaperTrailDiff.analyze_many([article, other], within: finish.., **options)

      expect(rows(batch)).to eq(rows(single))
      expect(rows(batch).flatten).not_to include('Robert')
      expect(rows(later.fetch(key(article))))
        .to include([:changed, 'author', 'name', 'Bob', 'Robert', 'U'])
    end

    it 'lists in `timeline` only the root versions a version filter keeps' do
      article = TrackedArticle.create!(title: 'one')
      comment = article.comments.create!(body: 'comment')
      start = Time.now
      in_transaction(1, 'bob') { article.update!(title: 'two') }
      in_transaction(2, 'alice') { comment.update!(body: 'edited') }
      in_transaction(3, 'bob') { article.update!(title: 'three') }
      alice = ->(scope) { scope.where(whodunnit: 'alice') }

      single, batch = both(article, within: start.., version_scope: alice, **options)

      expect([single.timeline, batch.timeline]).to eq([[], []])
      expect(rows(batch)).to eq([[:changed, 'comments', 'body', 'comment', 'edited', 'alice']])
    end

    # D destroys the article before the window and ends inside it.
    it 'reports a record destroyed by a transaction that ends in the window' do
      article = TrackedArticle.create!(title: 'one')
      comment = article.comments.create!(body: 'comment')
      in_transaction(1, 'D') do
        comment.destroy!
        article.destroy!
      end
      cut = Time.now
      in_transaction(1, 'D') { TrackedAuthor.create!(name: 'D goes on') }
      quiet = Time.now
      scoped = PaperTrailDiff.analyze_scope(TrackedArticle.all, limit: 10, include_deleted: true,
                                                                within: cut.., **options)

      reported = PaperTrailDiff.analyze(article, within: cut.., **options)

      expect(steps(reported.activity_timeline))
        .to eq(steps(scoped.deleted.fetch(key(article)).activity_timeline))
      expect(reported.activity_timeline.last.to_boundary).to be_destroyed
      expect(PaperTrailDiff.analyze(article, within: quiet.., **options).activity_timeline)
        .to eq([])
    end
  end

  # Each root version is reported where it was saved, so a window is read as
  # it is, however its transactions cross its edges. The records around a
  # root version read as they stood before every transaction that had not
  # ended yet.
  describe 'without activity' do
    let(:options) { { associations: [:comments] } }

    it 'reports a root version once when its transaction crosses the start' do
      article = TrackedArticle.create!(title: 'one')
      article.comments.create!(body: 'comment')
      start = Time.now
      in_transaction(1, 'T') { article.update!(title: 'two') }
      cut = Time.now
      in_transaction(1, 'T') { TrackedAuthor.create!(name: 'T goes on') }
      article.update!(title: 'three')

      before = both(article, within: start...cut, **options)
      after = both(article, within: cut.., **options)

      expect(before.map { |analysis| titles(analysis) }).to eq([[%w[one two]], [%w[one two]]])
      expect(after.map { |analysis| titles(analysis) }).to eq([[%w[two three]], [%w[two three]]])
    end

    it 'reports no root version saved after the window when a transaction crosses its end' do
      article = TrackedArticle.create!(title: 'one')
      comment = article.comments.create!(body: 'comment')
      start = Time.now
      article.update!(title: 'two')
      in_transaction(1, 'T') { comment.update!(body: 'T begins') }
      finish = Time.now
      article.update!(title: 'three')
      in_transaction(1, 'T') { comment.update!(body: 'T ends') }
      article.update!(title: 'four')

      single, batch = both(article, within: start...finish, **options)

      expect([titles(single), titles(batch)]).to eq([[%w[one two]], [%w[one two]]])
      expect(batch.diff.to_h).to eq(single.diff.to_h)
    end

    # S saves the comment, another transaction the article, and S the article:
    # the comment reads at S's article version as it stood before S.
    it 'reads a record at a root version as it stood before that version\'s transaction' do
      article = TrackedArticle.create!(title: 'one')
      comment = article.comments.create!(body: 'comment')
      start = Time.now
      in_transaction(1, 'S') { comment.update!(body: 'edited by S') }
      in_transaction(2, 'R') { article.update!(title: 'two') }
      in_transaction(1, 'S') { article.update!(title: 'three') }

      single, batch = both(article, within: start.., **options)

      expect(steps(batch.timeline)).to eq(steps(single.timeline))
    end

    # S edits the comment before the window; R saves the article inside it,
    # then S does. P, of another article, began before S, so a batch's
    # history starts before S's edit, and a single read's is read again from
    # there.
    it 'reports a change once, where its transaction ends, whatever else a batch reads' do
      article = TrackedArticle.create!(title: 'one')
      comment = article.comments.create!(body: 'comment')
      other = TrackedArticle.create!(title: 'other')
      other_comment = other.comments.create!(body: 'other comment')
      in_transaction(3, 'P') { other_comment.update!(body: 'P begins') }
      in_transaction(1, 'S') { comment.update!(body: 'edited by S') }
      start = Time.now
      in_transaction(3, 'P') { other.update!(title: 'other two') }
      in_transaction(2, 'R') { article.update!(title: 'two') }
      in_transaction(1, 'S') { article.update!(title: 'three') }
      article.update!(title: 'four')

      single, batch = both(article, [other], within: start.., **options)

      expect([bodies(single), bodies(batch)])
        .to eq([[nil, ['comment', 'edited by S'], nil]] * 2)
    end
  end

  # S renames the author before the article exists, R edits the comment, S
  # saves the article and R saves it too. An older article starts the batch's
  # history before S's rename, which began before the article's own history:
  # the article was created with the author as S had named it.
  describe 'a whole history, without a window' do
    def history_of_an_article_created_inside_a_transaction
      author = TrackedAuthor.create!(name: 'old')
      older = TrackedArticle.create!(title: 'older', author: author)
      in_transaction(1, 'S') { author.update!(name: 'new') }
      article = TrackedArticle.create!(title: 'one', author: author)
      comment = article.comments.create!(body: 'comment')
      in_transaction(2, 'R') { comment.update!(body: 'edited by R') }
      in_transaction(1, 'S') { article.update!(title: 'two') }
      in_transaction(2, 'R') { article.update!(title: 'three') }
      [article, older]
    end

    def renames(rows)
      rows.select { |_change, path, attribute, *| [path, attribute] == %w[author name] }
    end

    it 'reads the same with activity' do
      article, older = history_of_an_article_created_inside_a_transaction

      single, batch = both(article, [older], associations: %i[author comments], activity: true)

      expect(rows(batch)).to eq(rows(single))
      expect(renames(rows(batch)).map { |row| row.values_at(0, 3, 4) })
        .to eq([[:added, nil, 'new']])
    end

    it 'reads the same without activity' do
      article, older = history_of_an_article_created_inside_a_transaction

      single, batch = both(article, [older], associations: %i[author comments])

      expect(steps(batch.timeline)).to eq(steps(single.timeline))
      expect(batch.diff.to_h.dig(:associations, 'author')).to be_nil
    end
  end
end
