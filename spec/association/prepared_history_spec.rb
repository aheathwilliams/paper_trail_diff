# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe PaperTrailDiff::PreparedHistory do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedReply.delete_all
    TrackedComment.delete_all
    TrackedProfile.delete_all
    TrackedAuthorship.delete_all
    TrackedArticle.delete_all
    TrackedAuthor.delete_all
    TrackedTag.delete_all
  end

  def boundary_for(article)
    fresh = TrackedArticle.find(article.id)
    TrackedArticle.transaction { fresh.paper_trail.save_with_version }
    fresh.versions.reload.last
  end

  def normalizer(tree, traversal)
    PaperTrailDiff::SnapshotNormalizer.new(
      tree: tree,
      ignore_policy: PaperTrailDiff::IgnorePolicy.build(
        PaperTrailDiff::DEFAULT_IGNORED_ATTRIBUTES,
        association_paths: tree.paths
      ),
      traversal: traversal
    )
  end

  def normalize_version(version, tree, traversal, history: nil)
    record = version.reify(dup: true)
    fallback = PaperTrailDiff::HistoricalAssociationReifier.new(version)
    reifier = if history
                PaperTrailDiff::PreparedAssociationReifier.new(
                  history,
                  version,
                  habtm_boundary: version,
                  fallback: fallback
                )
              else
                fallback
              end
    normalizer(tree, traversal).call(record, reifier: reifier)
  end

  it 'matches PT-AT across direct, nested, through, and HABTM relationships' do
    first_author = TrackedAuthor.create!(name: 'Ada before')
    second_author = TrackedAuthor.create!(name: 'Grace before')
    article = TrackedArticle.create!(title: 'Prepared graph', author: first_author)
    profile = article.create_profile!(bio: 'Profile before')
    comment = article.comments.create!(body: 'Comment before')
    removed = article.comments.create!(body: 'Removed comment')
    reply = comment.replies.create!(body: 'Reply before')
    old_tag = TrackedTag.create!(name: 'Old tag')
    first_authorship = TrackedAuthorship.create!(
      article: article,
      author: first_author,
      role: 'lead'
    )
    article.tags << old_tag
    before = boundary_for(article)

    first_author.update!(name: 'Ada after')
    article.update!(author: second_author)
    profile.update!(bio: 'Profile after')
    comment.update!(body: 'Comment after')
    reply.update!(body: 'Reply after')
    removed.destroy!
    first_authorship.destroy!
    TrackedAuthorship.create!(article: article, author: second_author, role: 'contributor')
    article.comments.create!(body: 'Added comment')
    article.tags.delete(old_tag)
    new_tag = TrackedTag.create!(name: 'New tag')
    article.tags << new_tag
    after = boundary_for(article)

    associations = [
      'author.comments',
      'authorships.author',
      'contributors',
      'profile',
      'comments.replies',
      'tags'
    ]
    tree = PaperTrailDiff::AssociationTree.build(associations)
    traversal = PaperTrailDiff::AssociationTraversal.new(tree)
    root_versions = PaperTrailDiff::VersionRange.new(
      article,
      from: before,
      to: after
    ).select
    history = PaperTrailDiff::PreparedHistoryLoader.new(
      article,
      root_versions: root_versions,
      tree: tree,
      traversal: traversal
    ).call

    root = before.reify(dup: true)
    contributors = TrackedArticle.reflect_on_association(:contributors)
    tags = TrackedArticle.reflect_on_association(:tags)
    contributor_result = history.resolve(root, contributors, before, habtm_boundary: before)
    tag_result = history.resolve(root, tags, before, habtm_boundary: before)
    expect(contributor_result.first).to be(true)
    expect(contributor_result.last.map(&:id)).to eq([first_author.id])
    expect(tag_result.first).to be(true)
    expect(tag_result.last.map(&:id)).to eq([old_tag.id])
    missing_transaction = Struct.new(:transaction_id)
    expect(
      history.resolve(
        root,
        tags,
        before,
        habtm_boundary: missing_transaction.new(nil)
      ).first
    ).to be(false)
    expect(
      history.resolve(
        root,
        tags,
        before,
        habtm_boundary: missing_transaction.new(-1)
      ).first
    ).to be(false)

    root_versions.each do |version|
      indexed = normalize_version(version, tree, traversal, history: history)
      point = normalize_version(version, tree, traversal)
      expect(indexed.to_h).to eq(point.to_h), "prepared mismatch at root version #{version.id}"
    end
  end

  it 'delegates a reflection when prepared resolution is unavailable' do
    article = TrackedArticle.create!(title: 'Prepared fallback')
    version = article.versions.last
    reflection = TrackedArticle.reflect_on_association(:comments)
    history = instance_double(described_class)
    fallback = instance_double(PaperTrailDiff::HistoricalAssociationReifier)
    allow(history).to receive(:resolve).and_return([false, []])
    allow(fallback).to receive(:reify)
    reifier = PaperTrailDiff::PreparedAssociationReifier.new(
      history,
      version,
      habtm_boundary: version,
      fallback: fallback
    )

    reifier.reify(article, [reflection])
    reifier.reify(article, [reflection])

    expect(fallback).to have_received(:reify).once.with(article, [reflection])
  end

  it 'reconstructs empty optional, singular, collection, and HABTM edges' do
    article = TrackedArticle.create!(title: 'Prepared empty graph')
    before = boundary_for(article)
    article.update!(title: 'Prepared empty graph after')
    after = boundary_for(article)
    associations = %w[author profile comments tags]
    tree = PaperTrailDiff::AssociationTree.build(associations)
    traversal = PaperTrailDiff::AssociationTraversal.new(tree)
    root_versions = PaperTrailDiff::VersionRange.new(
      article,
      from: before,
      to: after
    ).select
    history = PaperTrailDiff::PreparedHistoryLoader.new(
      article,
      root_versions: root_versions,
      tree: tree,
      traversal: traversal
    ).call

    root_versions.each do |version|
      indexed = normalize_version(version, tree, traversal, history: history)
      point = normalize_version(version, tree, traversal)
      expect(indexed.to_h).to eq(point.to_h)
    end
  end
end
