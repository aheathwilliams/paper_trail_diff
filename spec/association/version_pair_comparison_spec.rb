# frozen_string_literal: true

require_relative '../support/association_database'

# PT-AT finds a has_many's children by the keys each version recorded after
# its change, so it cannot see a child that later moved to another owner at
# an earlier version. Comparing two versions must read prepared history, as
# a comparison with a live endpoint does.
RSpec.describe 'Comparing two versions of a root' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedReply, TrackedComment, TrackedArticle].each(&:delete_all)
  end

  def checkpoint(article)
    TrackedArticle.transaction { TrackedArticle.find(article.id).paper_trail.save_with_version }
    article.versions.reorder(:created_at, :id).last
  end

  def comments(diff)
    change = diff.associations['comments']
    return unless change

    { added: change.added.map { |comment| comment.attributes['body'] },
      removed: change.removed.map { |comment| comment.attributes['body'] },
      changed: change.changed.map { |comment| comment.attributes.fetch('body').to_h } }
  end

  def compare(from, to)
    PaperTrailDiff.compare(from, to, associations: [:comments])
  end

  let(:article) { TrackedArticle.create!(title: 'Article') }
  let(:other) { TrackedArticle.create!(title: 'Other') }

  it 'reports a child moved to another owner as removed from one and added to the other' do
    moved = article.comments.create!(body: 'moved')
    article.comments.create!(body: 'stays')
    from = checkpoint(article)
    other_from = checkpoint(other)
    moved.update!(article: other)
    to = checkpoint(article)
    other_to = checkpoint(other)

    expect(comments(compare(from, to))).to eq(added: [], removed: ['moved'], changed: [])
    expect(comments(compare(other_from, other_to)))
      .to eq(added: ['moved'], removed: [], changed: [])
  end

  it 'reports a destroyed child as removed' do
    article.comments.create!(body: 'destroyed')
    from = checkpoint(article)
    article.comments.first.destroy!
    to = checkpoint(article)

    expect(comments(compare(from, to))).to eq(added: [], removed: ['destroyed'], changed: [])
  end

  it 'reports a created child as added' do
    from = checkpoint(article)
    article.comments.create!(body: 'created')
    to = checkpoint(article)

    expect(comments(compare(from, to))).to eq(added: ['created'], removed: [], changed: [])
  end

  it 'reports an edited child as changed' do
    comment = article.comments.create!(body: 'before')
    from = checkpoint(article)
    comment.update!(body: 'after')
    to = checkpoint(article)

    expect(comments(compare(from, to)))
      .to eq(added: [], removed: [], changed: [{ from: 'before', to: 'after' }])
  end

  # The state at the later version is the one after it, which a change made
  # since then must not reach back into.
  it 'keeps a child that moved away only after the later version' do
    comment = article.comments.create!(body: 'kept')
    from = checkpoint(article)
    to = checkpoint(article)
    comment.update!(article: other, body: 'edited later')

    expect(compare(from, to).associations).to eq({})
  end

  it 'reports nothing between a version and itself' do
    article.comments.create!(body: 'kept')
    version = checkpoint(article)
    article.comments.first.update!(article: other)

    expect(compare(version, version)).to be_empty
  end

  it 'compares a root whose row was destroyed' do
    moved = article.comments.create!(body: 'moved')
    from = checkpoint(article)
    moved.update!(article: other)
    to = checkpoint(article)
    article.destroy!

    expect(comments(compare(from, to))).to eq(added: [], removed: ['moved'], changed: [])
  end

  it 'compares up to a root destroy version' do
    moved = article.comments.create!(body: 'moved')
    from = checkpoint(article)
    moved.update!(article: other)
    article.destroy!
    destroyed = article.versions.reorder(:created_at, :id).last

    expect(destroyed.event).to eq('destroy')
    expect(comments(compare(from, destroyed))).to eq(added: [], removed: ['moved'], changed: [])
  end

  it 'batches version pairs beside a pair with a live endpoint' do
    moved = article.comments.create!(body: 'moved')
    edited = other.comments.create!(body: 'edited')
    from = checkpoint(article)
    other_from = checkpoint(other)
    moved.update!(article: other)
    edited.update!(body: 'edited twice')
    to = checkpoint(article)
    third = TrackedArticle.create!(title: 'Third')
    third_from = checkpoint(third)
    third.comments.create!(body: 'created')

    results = PaperTrailDiff.compare_many(
      [{ from: from, to: to }, { from: other_from, to: other }, { from: third_from, to: third }],
      associations: [:comments]
    )

    expect(results.transform_values { |diff| comments(diff) }).to eq(
      ['TrackedArticle', article.id.to_s] => { added: [], removed: ['moved'], changed: [] },
      ['TrackedArticle', other.id.to_s] => {
        added: ['moved'], removed: [], changed: [{ from: 'edited', to: 'edited twice' }]
      },
      ['TrackedArticle', third.id.to_s] => { added: ['created'], removed: [], changed: [] }
    )
  end
end
