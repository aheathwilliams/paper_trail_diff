# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe 'PaperTrailDiff association tracking' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TrackedReply.delete_all
    TrackedComment.delete_all
    TrackedProfile.delete_all
    TrackedArticle.delete_all
    TrackedAuthor.delete_all
    TrackedTag.delete_all
  end

  def boundary_for(article)
    article.paper_trail.save_with_version
    article.versions.reload.last
  end

  def with_association_reify_behavior(value)
    previous = PaperTrail.config.association_reify_error_behaviour
    PaperTrail.config.association_reify_error_behaviour = value
    yield
  ensure
    PaperTrail.config.association_reify_error_behaviour = previous
  end

  def article_with_graph
    first_author = TrackedAuthor.create!(name: 'Ada')
    second_author = TrackedAuthor.create!(name: 'Grace')
    article = TrackedArticle.create!(title: 'Structured', author: first_author)
    graph = associated_graph(article)
    graph.merge(
      article: article,
      first_author: first_author,
      second_author: second_author,
      before: boundary_for(article)
    )
  end

  def associated_graph(article)
    profile = article.create_profile!(bio: 'Before')
    kept_comment = article.comments.create!(body: 'Keep before')
    removed_comment = article.comments.create!(body: 'Remove')
    reply = kept_comment.replies.create!(body: 'Nested before')
    removed_reply = kept_comment.replies.create!(body: 'Nested remove')

    {
      profile: profile,
      kept_comment: kept_comment,
      removed_comment: removed_comment,
      reply: reply,
      removed_reply: removed_reply
    }
  end

  it 'reports replacements, collection membership, and child updates separately' do
    graph = article_with_graph
    added_comment = nil
    TrackedArticle.transaction do
      graph[:article].update!(author: graph[:second_author])
      graph[:profile].update!(bio: 'After')
      graph[:kept_comment].update!(body: 'Keep after')
      graph[:removed_comment].destroy!
      added_comment = graph[:article].comments.create!(body: 'Added')
      graph[:reply].update!(body: 'Nested after')
    end
    after = boundary_for(graph[:article])

    result = PaperTrailDiff.compare(
      graph[:before],
      after,
      associations: %i[author profile comments]
    )

    author = result.associations.fetch('author')
    expect(author.relationship.from.id).to eq(graph[:first_author].id)
    expect(author.relationship.to.id).to eq(graph[:second_author].id)
    expect(author.changed).to be_nil
    expect(result.attributes).not_to have_key('author_id')

    profile = result.associations.fetch('profile')
    expect(profile.relationship).to be_nil
    expect(profile.changed.attributes.fetch('bio').to_h).to eq(from: 'Before', to: 'After')

    comments = result.associations.fetch('comments')
    expect(comments.added.map(&:id)).to eq([added_comment.id])
    expect(comments.removed.map(&:id)).to eq([graph[:removed_comment].id])
    expect(comments.changed.map { |change| change.record.fetch(:id) })
      .to eq([graph[:kept_comment].id])
    expect(comments.changed.first.attributes.fetch('body').to_h)
      .to eq(from: 'Keep before', to: 'Keep after')
  end

  it 'keeps a belongs_to foreign key scalar when the association is not selected' do
    graph = article_with_graph
    graph[:article].update!(author: graph[:second_author])
    after = boundary_for(graph[:article])

    result = PaperTrailDiff.compare(graph[:before], after)

    expect(result.attributes.fetch('author_id').to_h).to eq(
      from: graph[:first_author].id,
      to: graph[:second_author].id
    )
  end

  it 'reports has_one addition, removal, and replacement as relationships' do
    author = TrackedAuthor.create!(name: 'Ada')
    article = TrackedArticle.create!(title: 'Profile changes', author: author)
    without_profile = boundary_for(article)
    profile = article.create_profile!(bio: 'First')
    with_profile = boundary_for(article)

    addition = PaperTrailDiff.compare(without_profile, with_profile, associations: [:profile])
    expect(addition.associations.fetch('profile').relationship.to.id).to eq(profile.id)

    profile.destroy!
    after_removal = boundary_for(article)
    removal = PaperTrailDiff.compare(with_profile, after_removal, associations: [:profile])
    expect(removal.associations.fetch('profile').relationship.from.id).to eq(profile.id)
    expect(removal.associations.fetch('profile').relationship.to).to be_nil

    old_profile = article.create_profile!(bio: 'Old')
    before_replacement = boundary_for(article)
    old_profile.destroy!
    new_profile = article.create_profile!(bio: 'New')
    after_replacement = boundary_for(article)
    replacement = with_association_reify_behavior(:ignore) do
      PaperTrailDiff.compare(
        before_replacement,
        after_replacement,
        associations: [:profile]
      )
    end
    relationship = replacement.associations.fetch('profile').relationship
    expect([relationship.from.id, relationship.to.id]).to eq([old_profile.id, new_profile.id])
  end

  it 'does not recursively traverse grandchildren' do
    graph = article_with_graph
    graph[:reply].update!(body: 'Nested after')
    after = boundary_for(graph[:article])

    result = PaperTrailDiff.compare(graph[:before], after, associations: [:comments])

    expect(result).to be_empty
  end

  it 'reports nested collection additions, removals, and updates by explicit path' do
    graph = article_with_graph
    added_reply = nil
    TrackedArticle.transaction do
      graph[:reply].update!(body: 'Nested after')
      graph[:removed_reply].destroy!
      added_reply = graph[:kept_comment].replies.create!(body: 'Nested added')
    end
    after = boundary_for(graph[:article])

    result = PaperTrailDiff.compare(
      graph[:before],
      after,
      associations: ['comments.replies']
    )

    comment_change = result.associations.fetch('comments').changed.find do |change|
      change.record.fetch(:id) == graph[:kept_comment].id
    end
    replies = comment_change.associations.fetch('replies')
    expect(replies.added.map(&:id)).to eq([added_reply.id])
    expect(replies.removed.map(&:id)).to eq([graph[:removed_reply].id])
    expect(replies.changed.fetch(0).attributes.fetch('body').to_h)
      .to eq(from: 'Nested before', to: 'Nested after')
  end

  it 'keeps selected subtrees on newly added parent records' do
    graph = article_with_graph
    added_comment = graph[:article].comments.create!(body: 'Parent added')
    added_reply = added_comment.replies.create!(body: 'Child added')
    after = boundary_for(graph[:article])

    result = PaperTrailDiff.compare(
      graph[:before],
      after,
      associations: ['comments.replies']
    )

    comment = result.associations.fetch('comments').added.find do |snapshot|
      snapshot.id == added_comment.id
    end
    replies = comment.associations.fetch('replies')
    expect(replies.records.map(&:id)).to eq([added_reply.id])
    expect(comment.to_h.dig(:associations, 'replies', :records, 0, :attributes, 'body'))
      .to eq('Child added')
  end

  it 'reconstructs nested belongs_to and has_one paths at the root endpoints' do
    graph = article_with_graph
    TrackedArticle.transaction do
      graph[:article].update!(author: graph[:second_author])
      graph[:profile].update!(bio: 'Nested profile after')
    end
    after = boundary_for(graph[:article])

    result = PaperTrailDiff.compare(
      graph[:before],
      after,
      associations: ['comments.article.author', 'comments.article.profile']
    )

    comment = result.associations.fetch('comments').changed.find do |change|
      change.record.fetch(:id) == graph[:kept_comment].id
    end
    article = comment.associations.fetch('article').changed
    author = article.associations.fetch('author').relationship
    profile = article.associations.fetch('profile').changed
    expect([author.from.id, author.to.id])
      .to eq([graph[:first_author].id, graph[:second_author].id])
    expect(profile.attributes.fetch('bio').to_h)
      .to eq(from: 'Before', to: 'Nested profile after')
  end

  it 'reconstructs nested has_many through paths' do
    graph = article_with_graph
    added_comment = graph[:article].comments.create!(body: 'Through added')
    after = boundary_for(graph[:article])

    result = PaperTrailDiff.compare(
      graph[:before],
      after,
      associations: ['author.comments']
    )

    author = result.associations.fetch('author').changed
    comments = author.associations.fetch('comments')
    expect(comments.added.map(&:id)).to eq([added_comment.id])
  end

  it 'applies ignore rules to exact association paths' do
    graph = article_with_graph
    TrackedArticle.transaction do
      graph[:article].update!(title: 'Structured after')
      graph[:reply].update!(body: 'Nested after')
    end
    after = boundary_for(graph[:article])

    result = PaperTrailDiff.compare(
      graph[:before],
      after,
      associations: ['comments.replies'],
      ignore: {
        all: [],
        paths: { 'comments.replies': [:updated_at] }
      }
    )

    expect(result.attributes).to include('title', 'updated_at')
    comment = result.associations.fetch('comments').changed.find do |change|
      change.record.fetch(:id) == graph[:kept_comment].id
    end
    reply = comment.associations.fetch('replies').changed.fetch(0)
    expect(reply.attributes).to have_key('body')
    expect(reply.attributes).not_to have_key('updated_at')
  end

  it 'includes selected association changes in timeline steps' do
    graph = article_with_graph
    graph[:kept_comment].update!(body: 'Timeline after')
    after = boundary_for(graph[:article])

    steps = PaperTrailDiff.timeline(
      graph[:article],
      from: graph[:before],
      to: after,
      associations: [:comments]
    )

    change = steps.fetch(0).diff.associations.fetch('comments').changed.fetch(0)
    expect(change.attributes.fetch('body').to_h)
      .to eq(from: 'Keep before', to: 'Timeline after')
  end

  it 'includes explicitly selected nested changes in timeline steps' do
    graph = article_with_graph
    graph[:reply].update!(body: 'Timeline nested after')
    after = boundary_for(graph[:article])

    steps = PaperTrailDiff.timeline(
      graph[:article],
      from: graph[:before],
      to: after,
      associations: ['comments.replies']
    )

    comments = steps.fetch(0).diff.associations.fetch('comments')
    comment = comments.changed.find do |change|
      change.record.fetch(:id) == graph[:kept_comment].id
    end
    reply = comment.associations.fetch('replies').changed.fetch(0)
    expect(reply.attributes.fetch('body').to_h)
      .to eq(from: 'Nested before', to: 'Timeline nested after')
  end

  it 'rejects unknown and unsupported associations' do
    graph = article_with_graph

    expect do
      PaperTrailDiff.compare(graph[:before], graph[:before], associations: [:missing])
    end.to raise_error(PaperTrailDiff::UnknownAssociationError, /missing/)

    expect do
      PaperTrailDiff.compare(
        graph[:before],
        graph[:before],
        associations: ['comments.missing']
      )
    end.to raise_error(PaperTrailDiff::UnknownAssociationError, /comments\.missing/)

    expect do
      PaperTrailDiff.compare(graph[:before], graph[:before], associations: [:tags])
    end.to raise_error(PaperTrailDiff::UnsupportedAssociationError, /tags/)
  end
end
