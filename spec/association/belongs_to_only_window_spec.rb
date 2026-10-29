# frozen_string_literal: true

require_relative '../support/association_database'

# The root has no version in the window, so the targets it points at come from
# its state when the window opened rather than from changes of its own.
RSpec.describe 'Activity windows where only a belongs_to target changed' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedComment, TrackedAuthorship, TrackedArticle, TrackedAuthor].each(&:delete_all)
  end

  def analyses(article, path, window)
    options = { within: window, associations: [path], activity: true }
    single = PaperTrailDiff.analyze(article, **options)
    batch = PaperTrailDiff.analyze_many([article], **options)
                          .fetch(PaperTrailDiff::Endpoint.identity(article))
    [single, batch]
  end

  def renamed(diff, path)
    association = diff.associations.fetch(path)
    changes = association.respond_to?(:changed) ? Array(association.changed) : []
    changes.map { |change| change.attributes.fetch('name').to_h }
  end

  it 'reports an author renamed under an article nobody edited' do
    author = TrackedAuthor.create!(name: 'Ann')
    article = TrackedArticle.create!(title: 'Quiet', author: author)
    window_start = Time.now.utc
    author.update!(name: 'Anne')

    single, batch = analyses(article, :author, window_start..Time.now.utc)

    expect(renamed(single.diff, 'author')).to eq([{ from: 'Ann', to: 'Anne' }])
    expect(batch.diff.to_h).to eq(single.diff.to_h)
    expect(single.activity_timeline.reject(&:empty?).map { |step| step.source_boundary.item_type })
      .to eq(['TrackedAuthor'])
  end

  it 'reports a through source renamed when neither the article nor the join row changed' do
    article = TrackedArticle.create!(title: 'Quiet')
    writer = TrackedAuthor.create!(name: 'Wes')
    TrackedAuthorship.create!(article: article, author: writer, role: 'writer')
    window_start = Time.now.utc
    writer.update!(name: 'Wesley')

    single, batch = analyses(article, :contributors, window_start..Time.now.utc)

    expect(renamed(single.diff, 'contributors')).to eq([{ from: 'Wes', to: 'Wesley' }])
    expect(batch.diff.to_h).to eq(single.diff.to_h)
  end

  it 'reports a reviewer renamed under a comment that did not change, in a closed window' do
    article = TrackedArticle.create!(title: 'Quiet')
    reviewer = TrackedAuthor.create!(name: 'Rev')
    article.comments.create!(body: 'Looks good', reviewer: reviewer)
    window_start = Time.now.utc
    reviewer.update!(name: 'Reva')
    window_end = Time.now.utc
    TrackedArticle.transaction { TrackedArticle.find(article.id).paper_trail.save_with_version }

    single, batch = analyses(article, 'comments.reviewer', window_start..window_end)

    comment = single.diff.associations.fetch('comments').changed.first
    expect(renamed(comment, 'reviewer')).to eq([{ from: 'Rev', to: 'Reva' }])
    expect(batch.diff.to_h).to eq(single.diff.to_h)
  end

  it 'reports a change to the author an article pointed at before it moved in the window' do
    first = TrackedAuthor.create!(name: 'Ann')
    second = TrackedAuthor.create!(name: 'Bea')
    article = TrackedArticle.create!(title: 'Moving', author: first)
    window_start = Time.now.utc
    first.update!(name: 'Anne')
    article.update!(author: second)

    single, batch = analyses(article, :author, window_start..Time.now.utc)
    sources = single.activity_timeline.reject(&:empty?).map do |step|
      step.source_boundary.item_type
    end

    expect(sources).to eq(%w[TrackedAuthor TrackedArticle])
    expect(batch.activity_timeline.map { |step| step.diff.to_h })
      .to eq(single.activity_timeline.map { |step| step.diff.to_h })
  end

  # The version that closes the window records the author the article points
  # at after it, which the window never reached.
  it 'leaves out the author an article moves to when the window closes' do
    first = TrackedAuthor.create!(name: 'Ann')
    second = TrackedAuthor.create!(name: 'Bea')
    article = TrackedArticle.create!(title: 'Moving', author: first)
    window_start = Time.now.utc
    article.update!(title: 'Moved')
    second.update!(name: 'Beatrice')
    window_end = Time.now.utc
    article.update!(author: second)

    analyses(article, :author, window_start..window_end).each do |analysis|
      expect(analysis.activity_timeline.map { |step| step.source_boundary.item_type })
        .to eq(['TrackedArticle'])
    end
  end
end
