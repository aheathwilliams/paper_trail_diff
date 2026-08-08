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

  def habtm_boundary_for(article)
    fresh_article = TrackedArticle.find(article.id)
    TrackedArticle.transaction { fresh_article.paper_trail.save_with_version }
    fresh_article.versions.reload.last
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
    expect(comments.added.first.attributes).not_to have_key('article_id')
    expect(comments.removed.first.attributes).not_to have_key('article_id')
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
    expect(replies.added.first.attributes).not_to have_key('comment_id')
    expect(replies.removed.first.attributes).not_to have_key('comment_id')
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

  it 'reconstructs a removed through collection before resolving its targets' do
    author = TrackedAuthor.create!(name: 'Through owner')
    article = TrackedArticle.create!(title: 'Through parent', author: author)
    comment = article.comments.create!(body: 'Through child')
    before = boundary_for(author)
    article.destroy!
    after = boundary_for(author)

    result = PaperTrailDiff.compare(before, after, associations: [:comments])

    expect(result.associations.fetch('comments').removed.map(&:id)).to eq([comment.id])
    expect(PaperTrailDiff.diagnose(before, after, associations: [:comments])).to be_ok
  end

  it 'reports HABTM membership and target attribute changes as a collection' do
    graph = article_with_graph
    kept_tag = TrackedTag.create!(name: 'Kept before')
    removed_tag = TrackedTag.create!(name: 'Removed')
    graph[:article].tags << [kept_tag, removed_tag]
    before = habtm_boundary_for(graph[:article])

    kept_tag.update!(name: 'Kept after')
    graph[:article].tags.delete(removed_tag)
    added_tag = TrackedTag.create!(name: 'Added')
    graph[:article].tags << added_tag
    after = habtm_boundary_for(graph[:article])

    result = PaperTrailDiff.compare(before, after, associations: [:tags])
    tags = result.associations.fetch('tags')

    expect(tags.kind).to eq(:has_and_belongs_to_many)
    expect(tags.added.map(&:id)).to eq([added_tag.id])
    expect(tags.removed.map(&:id)).to eq([removed_tag.id])
    expect(tags.changed.fetch(0).attributes.fetch('name').to_h)
      .to eq(from: 'Kept before', to: 'Kept after')

    step_tags = PaperTrailDiff.timeline(
      graph[:article],
      from: before,
      to: after,
      associations: [:tags]
    ).fetch(0).diff.associations.fetch('tags')
    expect(step_tags.to_h).to eq(tags.to_h)
  end

  it 'reconstructs nested HABTM paths and bounds cyclic paths explicitly' do
    graph = article_with_graph
    kept_tag = TrackedTag.create!(name: 'Nested before')
    graph[:article].tags << kept_tag
    before = habtm_boundary_for(graph[:article])

    kept_tag.update!(name: 'Nested after')
    after = habtm_boundary_for(graph[:article])
    result = PaperTrailDiff.compare(
      before,
      after,
      associations: ['comments.article.tags']
    )

    comment = result.associations.fetch('comments').changed.find do |change|
      change.record.fetch(:id) == graph[:kept_comment].id
    end
    article = comment.associations.fetch('article').changed
    tag_change = article.associations.fetch('tags').changed.fetch(0)
    expect(tag_change.attributes.fetch('name').to_h)
      .to eq(from: 'Nested before', to: 'Nested after')

    cyclic = PaperTrailDiff.compare(
      before,
      before,
      associations: ['tags.articles.tags']
    )
    expect(cyclic).to be_empty
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

  it 'rejects unknown associations' do
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
      PaperTrailDiff.compare(graph[:before], graph[:before], associations: [:versions])
    end.to raise_error(PaperTrailDiff::UnsupportedAssociationError, /PaperTrail versions/)
  end

  it 'discovers supported association paths with targets, through edges, and cycles' do
    descriptors = PaperTrailDiff.association_paths(TrackedArticle, max_depth: 2)
    by_path = descriptors.to_h { |descriptor| [descriptor.path, descriptor] }

    expect(PaperTrailDiff.supported_association_macros).to eq(
      %i[belongs_to has_one has_many has_and_belongs_to_many]
    )
    expect(descriptors).to be_frozen
    expect(descriptors.map(&:path)).to eq(descriptors.map(&:path).sort)
    expect(by_path.fetch('comments.replies').to_h).to include(
      kind: :has_many,
      target_type: 'TrackedReply',
      cycle: false
    )
    expect(by_path.fetch('comments.article').cycle).to be(true)
    expect(by_path.fetch('author.comments').through).to eq('articles')
    expect(PaperTrailDiff.association_paths(TrackedArticle).map(&:path))
      .to eq(%w[author comments profile tags])
    expect(PaperTrailDiff.association_paths(TrackedArticle.new).map(&:path))
      .to eq(%w[author comments profile tags])
  end

  it 'separates descendant updates into activity timeline steps' do
    graph = article_with_graph
    graph[:first_author].update!(name: 'Ada after')
    graph[:kept_comment].update!(body: 'Comment after')
    graph[:reply].update!(body: 'Reply after')
    after = boundary_for(graph[:article])

    steps = PaperTrailDiff.activity_timeline(
      graph[:article],
      from: graph[:before],
      to: after,
      associations: ['author.comments', 'comments.replies']
    )
    changed_steps = steps.reject { |step| step.diff.empty? }

    expect(changed_steps.map { |step| step.from_version.item_type })
      .to eq(%w[TrackedAuthor TrackedComment TrackedReply])
    expect(changed_steps.fetch(0).diff.associations.fetch('author').changed.attributes)
      .to have_key('name')
    expect(changed_steps.fetch(1).diff.associations.fetch('comments').changed.first.attributes)
      .to have_key('body')
    reply = changed_steps.fetch(2).diff.associations.fetch('comments').changed
                         .first.associations.fetch('replies').changed.first
    expect(reply.attributes.fetch('body').to_h)
      .to eq(from: 'Nested before', to: 'Reply after')

    empty = PaperTrailDiff.activity_timeline(
      graph[:article],
      from: graph[:before],
      to: graph[:before]
    )
    expect(empty).to eq([])
    expect(empty).to be_frozen
    expect do
      PaperTrailDiff.activity_timeline(
        graph[:article],
        from: after,
        to: graph[:before]
      )
    end.to raise_error(PaperTrailDiff::InvalidTimelineRangeError, /must not follow/)
  end

  it 'reports child additions and removals at their own activity boundaries' do
    graph = article_with_graph
    transient = graph[:article].comments.create!(body: 'Transient')
    graph[:kept_comment].update!(body: 'Kept after')
    transient.destroy!
    after = boundary_for(graph[:article])

    changed = PaperTrailDiff.activity_timeline(
      graph[:article],
      from: graph[:before],
      to: after,
      associations: [:comments]
    ).reject { |step| step.diff.empty? }
    comment_diffs = changed.map { |step| step.diff.associations.fetch('comments') }

    expect(comment_diffs.map { |diff| diff.added.map(&:id) })
      .to eq([[transient.id], [], []])
    expect(comment_diffs.map { |diff| diff.removed.map(&:id) })
      .to eq([[], [], [transient.id]])
    expect(comment_diffs.fetch(1).changed.first.attributes).to have_key('body')
  end

  it 'uses owner checkpoints for HABTM activity membership while diffing target updates' do
    graph = article_with_graph
    tag = TrackedTag.create!(name: 'Activity before')
    graph[:article].tags << tag
    before = habtm_boundary_for(graph[:article])
    tag.update!(name: 'Activity after')
    after = habtm_boundary_for(graph[:article])

    changed = PaperTrailDiff.activity_timeline(
      graph[:article],
      from: before,
      to: after,
      associations: [:tags]
    ).reject { |step| step.diff.empty? }
    tags = changed.fetch(0).diff.associations.fetch('tags')

    expect(tags.added).to be_empty
    expect(tags.removed).to be_empty
    expect(tags.changed.first.attributes.fetch('name').to_h)
      .to eq(from: 'Activity before', to: 'Activity after')
    expect(PaperTrailDiff.diagnose(before, after, associations: [:tags])).to be_ok
  end

  it 'fails loudly and diagnoses HABTM endpoints without transaction snapshots' do
    graph = article_with_graph
    after = boundary_for(graph[:article])

    expect do
      PaperTrailDiff.compare(graph[:before], after, associations: [:tags])
    end.to raise_error(
      PaperTrailDiff::IncompleteAssociationHistoryError,
      /HABTM history is incomplete/
    )

    report = PaperTrailDiff.diagnose(graph[:before], after, associations: [:tags])
    expect(report).not_to be_ok
    expect(report.errors.map(&:code)).to eq(%i[transaction_id_missing transaction_id_missing])
  end

  it 'warns when HABTM checkpoints synchronize version timestamps' do
    graph = article_with_graph
    tag = TrackedTag.create!(name: 'Timestamp')
    graph[:article].tags << tag
    before = habtm_boundary_for(graph[:article])
    after = habtm_boundary_for(graph[:article])
    options = TrackedArticle.paper_trail_options
    previous = options[:synchronize_version_creation_timestamp]
    options[:synchronize_version_creation_timestamp] = true

    report = PaperTrailDiff.diagnose(before, after, associations: [:tags])

    expect(report.warnings.map(&:code)).to eq([:synchronized_version_timestamp])
  ensure
    options[:synchronize_version_creation_timestamp] = previous if options
  end

  it 'diagnoses ordinary tracked association targets as usable' do
    graph = article_with_graph
    after = boundary_for(graph[:article])

    report = PaperTrailDiff.diagnose(graph[:before], after, associations: [:author])

    expect(report).to be_ok
    expect(report.issues).to be_empty
    expect(PaperTrailDiff.diagnose(graph[:before], after)).to be_ok
    expect do
      PaperTrailDiff.diagnose(graph[:before], after, associations: [:missing])
    end.to raise_error(PaperTrailDiff::UnknownAssociationError, /missing/)
  end
end
