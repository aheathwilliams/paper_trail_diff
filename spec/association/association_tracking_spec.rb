# frozen_string_literal: true

require_relative '../support/association_database'

RSpec.describe 'PaperTrailDiff association tracking' do
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

  def sql_query_count(&block)
    count = 0
    callback = proc do |_name, _start, _finish, _id, payload|
      next if payload[:name] == 'SCHEMA' || payload[:cached]

      count += 1
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    count
  end

  def database_work(&block) # rubocop:disable Metrics/MethodLength
    queries = 0
    records = 0
    sql_callback = proc do |_name, _start, _finish, _id, payload|
      next if payload[:name] == 'SCHEMA' || payload[:cached]

      queries += 1
    end
    instantiation_callback = proc do |_name, _start, _finish, _id, payload|
      records += payload[:record_count].to_i
    end
    ActiveSupport::Notifications.subscribed(sql_callback, 'sql.active_record') do
      ActiveSupport::Notifications.subscribed(
        instantiation_callback,
        'instantiation.active_record',
        &block
      )
    end
    { queries: queries, records: records }
  end

  def full_activity_timeline(record, from:, to:, associations:)
    tree = PaperTrailDiff::AssociationTree.build(associations)
    adapter = PaperTrailDiff::PaperTrailAdapter.new(
      associations: associations,
      ignore: PaperTrailDiff::DEFAULT_IGNORED_ATTRIBUTES
    )
    PaperTrailDiff::ActivityTimelineBuilder.new(
      record,
      from: from,
      to: to,
      tree: tree,
      snapshotter: adapter.method(:snapshot_at)
    ).build
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

  it 'compares historical associations with current state without a root checkpoint' do
    graph = article_with_graph
    graph[:kept_comment].update!(body: 'Live after')
    added = graph[:article].comments.create!(body: 'Live added')

    result = PaperTrailDiff.compare(
      graph[:before],
      graph[:article],
      associations: ['comments.replies']
    )
    comments = result.associations.fetch('comments')

    expect(comments.added.map(&:id)).to eq([added.id])
    expect(comments.changed.fetch(0).attributes.fetch('body').to_h)
      .to eq(from: 'Keep before', to: 'Live after')
    expect(comments.added.first.attributes).not_to have_key('article_id')
  end

  it 'compares a transaction-backed HABTM version with live membership' do
    graph = article_with_graph
    before = habtm_boundary_for(graph[:article])
    tag = TrackedTag.create!(name: 'Live tag')
    graph[:article].tags << tag

    result = PaperTrailDiff.compare(before, graph[:article], associations: [:tags])

    expect(result.associations.fetch('tags').added.map(&:id)).to eq([tag.id])
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
      .to eq(%w[author authorships comments contributors profile tags])
    expect(PaperTrailDiff.association_paths(TrackedArticle.new).map(&:path))
      .to eq(%w[author authorships comments contributors profile tags])
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

    expect(changed_steps.map { |step| step.from_boundary.item_type })
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

  it 'reuses root snapshots when analysis includes activity' do
    graph = article_with_graph
    graph[:kept_comment].update!(body: 'Shared activity')
    after = boundary_for(graph[:article])
    associations = ['comments.replies']

    separate_queries = sql_query_count do
      PaperTrailDiff.analyze(
        graph[:article],
        from: graph[:before],
        to: after,
        associations: associations
      )
      PaperTrailDiff.activity_timeline(
        graph[:article],
        from: graph[:before],
        to: after,
        associations: associations
      )
    end
    combined_queries = sql_query_count do
      result = PaperTrailDiff.analyze(
        graph[:article],
        from: graph[:before],
        to: after,
        associations: associations,
        activity: true
      )
      expect(result.activity_timeline).not_to be_empty
    end

    expect(combined_queries).to be < separate_queries
  end

  it 'derives all combined views from the activity snapshots without changing output' do
    graph = article_with_graph
    tag = TrackedTag.create!(name: 'Combined tag before')
    graph[:article].tags << tag
    before = habtm_boundary_for(graph[:article])
    graph[:article].update!(title: 'Combined root after')
    graph[:article].update!(author: graph[:second_author])
    graph[:kept_comment].update!(body: 'Combined comment after')
    graph[:reply].update!(body: 'Combined reply after')
    tag.update!(name: 'Combined tag after')
    after = habtm_boundary_for(graph[:article])
    associations = ['author.comments', 'comments.replies', 'profile', 'tags']

    root = PaperTrailDiff.analyze(
      graph[:article],
      from: before,
      to: after,
      associations: associations
    )
    activity = PaperTrailDiff.activity_timeline(
      graph[:article],
      from: before,
      to: after,
      associations: associations
    )
    combined = PaperTrailDiff.analyze(
      graph[:article],
      from: before,
      to: after,
      associations: associations,
      activity: true
    )

    expect(combined.diff.to_h).to eq(root.diff.to_h)
    expect(combined.timeline.map(&:to_h)).to eq(root.timeline.map(&:to_h))
    expect(combined.activity_timeline.map(&:to_h)).to eq(activity.map(&:to_h))
  end

  it 'prepares ordinary root timelines without changing point-reifier output' do
    graph = article_with_graph
    graph[:article].update!(title: 'Prepared root one')
    graph[:kept_comment].update!(body: 'Prepared child')
    graph[:article].update!(title: 'Prepared root two')
    after = boundary_for(graph[:article])
    associations = ['author.comments', 'comments.replies', 'profile']
    optimized = nil
    optimized_queries = sql_query_count do
      optimized = PaperTrailDiff.analyze(
        graph[:article],
        from: graph[:before],
        to: after,
        associations: associations
      )
    end
    adapter = PaperTrailDiff::PaperTrailAdapter.new(
      associations: associations,
      ignore: PaperTrailDiff::DEFAULT_IGNORED_ATTRIBUTES
    )
    reference = nil
    reference_queries = sql_query_count do
      reference = PaperTrailDiff::TimelineBuilder.new(
        graph[:article],
        from: graph[:before],
        to: after,
        snapshotter: adapter.method(:uncached_historical_snapshot)
      ).analyze
    end

    expect(optimized.diff.to_h).to eq(reference.diff.to_h)
    expect(optimized.timeline.map(&:to_h)).to eq(reference.timeline.map(&:to_h))
    expect(optimized_queries).to be < reference_queries
  end

  it 'advances isolated root changes without rebuilding direct versioned branches' do
    article = TrackedArticle.create!(title: 'Root sequence')
    article.comments.create!(body: 'Stable child')
    before = boundary_for(article)
    20.times { |index| article.update!(title: "Root sequence #{index}") }
    after = boundary_for(article)

    work = database_work do
      result = PaperTrailDiff.analyze(
        article,
        from: before,
        to: after,
        associations: [:comments],
        activity: true
      )
      expect(result.timeline.length).to eq(21)
      expect(result.diff.attributes.fetch('title').to).to eq('Root sequence 19')
    end

    expect(work.fetch(:queries)).to be < 15
    expect(work.fetch(:records)).to be < 75
  end

  it 'matches full reconstruction while refreshing only affected branches' do
    graph = article_with_graph
    TrackedArticle.transaction do
      graph[:first_author].update!(name: 'Branch author')
      graph[:profile].update!(bio: 'Branch profile')
      graph[:kept_comment].update!(body: 'Branch comment')
      graph[:reply].update!(body: 'Branch reply')
    end
    after = boundary_for(graph[:article])
    associations = ['author.comments', 'comments.replies', 'profile']

    optimized = PaperTrailDiff.activity_timeline(
      graph[:article],
      from: graph[:before],
      to: after,
      associations: associations
    )
    reference = full_activity_timeline(
      graph[:article],
      from: graph[:before],
      to: after,
      associations: associations
    )

    expect(optimized.map(&:to_h)).to eq(reference.map(&:to_h))
    expect(optimized.map { |step| step.from_boundary.item_type })
      .to include('TrackedAuthor')
  end

  it 'keeps same-branch descendant events atomic within one transaction' do
    article = TrackedArticle.create!(title: 'Atomic descendants')
    comment = article.comments.create!(body: 'Parent')
    replies = 2.times.map { |index| comment.replies.create!(body: "Reply #{index}") }
    before = boundary_for(article)
    TrackedReply.transaction { replies.each(&:destroy!) }
    after = boundary_for(article)
    associations = ['comments.replies']

    optimized = PaperTrailDiff.activity_timeline(
      article,
      from: before,
      to: after,
      associations: associations
    )
    reference = full_activity_timeline(
      article,
      from: before,
      to: after,
      associations: associations
    )

    expect(optimized.map(&:to_h)).to eq(reference.map(&:to_h))
    transaction_steps = optimized.select do |step|
      step.from_boundary.item_type == 'TrackedReply'
    end
    expect(transaction_steps.first.diff).to be_empty
    expect(transaction_steps.last.diff.empty?).to be(false)
  end

  it 'uses fewer queries for independent changes on unrelated branches' do
    graph = article_with_graph
    graph[:first_author].update!(name: 'Independent author')
    graph[:profile].update!(bio: 'Independent profile')
    graph[:reply].update!(body: 'Independent reply')
    after = boundary_for(graph[:article])
    associations = ['author', 'comments.replies', 'profile']

    optimized_queries = sql_query_count do
      PaperTrailDiff.activity_timeline(
        graph[:article],
        from: graph[:before],
        to: after,
        associations: associations
      )
    end
    reference_queries = sql_query_count do
      full_activity_timeline(
        graph[:article],
        from: graph[:before],
        to: after,
        associations: associations
      )
    end

    expect(optimized_queries).to be < reference_queries
  end

  it 'keeps direct collection activity work linear when selected children are nested' do
    article = TrackedArticle.create!(title: 'Scaled activity')
    comments = 20.times.map do |index|
      comment = article.comments.create!(body: "Approval #{index}")
      comment.replies.create!(body: "Approver #{index}")
      comment
    end
    before = boundary_for(article)
    comments.each_with_index do |comment, index|
      comment.update!(body: "Reapproved #{index}")
    end
    after = boundary_for(article)

    work = database_work do
      steps = PaperTrailDiff.activity_timeline(
        article,
        from: before,
        to: after,
        associations: ['comments.replies']
      )
      expect(steps.length).to eq(21)
    end

    expect(work.fetch(:queries)).to be < 300
    expect(work.fetch(:records)).to be < 500
  end

  it 'advances ordinary child updates without per-event live-record queries' do
    article = TrackedArticle.create!(title: 'Serialized activity changes')
    comments = 30.times.map do |index|
      article.comments.create!(body: "Approval #{index}")
    end
    before = boundary_for(article)
    comments.each_with_index do |comment, index|
      comment.update!(body: "Reapproved #{index}")
    end
    after = boundary_for(article)

    work = database_work do
      PaperTrailDiff.activity_timeline(
        article,
        from: before,
        to: after,
        associations: [:comments]
      )
    end

    expect(work.fetch(:queries)).to be < 25
  end

  it 'keeps nested collection activity local to the affected parent snapshots' do
    article = TrackedArticle.create!(title: 'Scaled nested activity')
    replies = 20.times.map do |index|
      comment = article.comments.create!(body: "Approval #{index}")
      comment.replies.create!(body: "Approver #{index}")
    end
    before = boundary_for(article)
    replies.each_with_index do |reply, index|
      reply.update!(body: "Reapproved #{index}")
    end
    after = boundary_for(article)

    work = database_work do
      steps = PaperTrailDiff.activity_timeline(
        article,
        from: before,
        to: after,
        associations: ['comments.replies']
      )
      expect(steps.length).to eq(21)
    end

    expect(work.fetch(:queries)).to be < 300
    expect(work.fetch(:records)).to be < 500
  end

  it 'does not instantiate out-of-range child history for a leaf collection' do
    article = TrackedArticle.create!(title: 'Bounded activity')
    comments = 5.times.map do |index|
      article.comments.create!(body: "Approval #{index}")
    end
    50.times do |round|
      comments.each { |comment| comment.update!(body: "Old #{round}") }
    end
    before = boundary_for(article)
    comments.each_with_index do |comment, index|
      comment.update!(body: "Current #{index}")
    end
    after = boundary_for(article)

    work = database_work do
      PaperTrailDiff.activity_timeline(
        article,
        from: before,
        to: after,
        associations: [:comments]
      )
    end

    expect(work.fetch(:records)).to be < 100
  end

  it 'applies nested belongs-to target updates without rebuilding the parent collection' do
    reviewer = TrackedAuthor.create!(name: 'Reviewer before')
    article = TrackedArticle.create!(title: 'Nested target')
    comments = 3.times.map do |index|
      article.comments.create!(body: "Approval #{index}", reviewer: reviewer)
    end
    before = boundary_for(article)
    comments.first.update!(body: 'Discover nested reviewer')
    reviewer.update!(name: 'Reviewer after')
    reviewer.destroy!
    after = boundary_for(article)
    associations = ['comments.reviewer']

    optimized = PaperTrailDiff.activity_timeline(
      article,
      from: before,
      to: after,
      associations: associations
    )
    reference = full_activity_timeline(
      article,
      from: before,
      to: after,
      associations: associations
    )

    expect(optimized.map(&:to_h)).to eq(reference.map(&:to_h))
    expect(optimized.map { |step| step.from_boundary.item_type })
      .to include('TrackedAuthor')
  end

  it 'applies direct-child membership deltas against an existing immutable snapshot' do
    article = TrackedArticle.create!(title: 'Original owner')
    other = TrackedArticle.create!(title: 'New owner')
    comment = article.comments.create!(body: 'Moving approval')
    before = boundary_for(article)
    comment.update!(article: other)
    comment_version = comment.versions.last
    after = boundary_for(article)
    tree = PaperTrailDiff::AssociationTree.build([:comments])
    traversal = PaperTrailDiff::AssociationTraversal.new(tree)
    pool = PaperTrailDiff::SnapshotPool.new
    normalizer = PaperTrailDiff::SnapshotNormalizer.new(
      tree: tree,
      ignore_policy: PaperTrailDiff::IgnorePolicy.build(
        PaperTrailDiff::DEFAULT_IGNORED_ATTRIBUTES,
        association_paths: tree.paths
      ),
      traversal: traversal,
      pool: pool
    )
    refresher = PaperTrailDiff::ActivityEventSnapshotRefresher.new(
      traversal: traversal,
      pool: pool,
      components: ->(_branches) { [tree, normalizer] }
    )
    comment_snapshot = PaperTrailDiff::RecordSnapshot.new(
      type: 'TrackedComment',
      id: comment.id,
      attributes: { body: 'Moving approval' }
    )
    previous = PaperTrailDiff::RecordSnapshot.new(
      type: 'TrackedArticle',
      id: article.id,
      attributes: { title: article.title },
      associations: {
        comments: PaperTrailDiff::AssociationSnapshot.new(
          kind: :has_many,
          records: [comment_snapshot]
        )
      }
    )
    event = PaperTrailDiff::ActivityEvent.new(
      version: comment_version,
      branches: ['comments']
    )

    handled, updated = refresher.call(after, after, previous, ['comments'], event)
    expect(handled).to be(true)
    expect(updated.associations.fetch('comments').records).to be_empty

    handled, unchanged = refresher.call(before, after, previous, [], nil)
    expect(handled).to be(false)
    expect(unchanged).to be_nil

    polymorphic = instance_double(
      ActiveRecord::Reflection::AssociationReflection,
      foreign_key: :subject_id,
      options: { as: :subject },
      type: :subject_type,
      active_record: TrackedArticle
    )
    subject = Struct.new(:subject_id, :subject_type).new(article.id, 'TrackedArticle')
    expect(refresher.send(:member_of_owner?, subject, polymorphic, previous)).to be(true)
    subject.subject_type = 'OtherType'
    expect(refresher.send(:member_of_owner?, subject, polymorphic, previous)).to be(false)

    irrelevant = instance_double(PaperTrail::Version, event: 'touch')
    expect(refresher.send(:changed_record_after, irrelevant)).to be_nil
    missing_record = instance_double(PaperTrail::Version, reify: nil)
    expect(refresher.send(:updated_record_after, missing_record)).to be_nil

    create_version = comment.versions.find_by!(event: 'create')
    allow(refresher).to receive(:deserialized_changeset).and_return(nil)
    expect(refresher.send(:created_record_after, create_version)).to be_nil
  end

  it 'reuses equal immutable nodes and short-circuits shared snapshot comparisons' do
    pool = PaperTrailDiff::SnapshotPool.new
    record = PaperTrailDiff::RecordSnapshot.new(
      type: 'TrackedComment',
      id: 1,
      attributes: { body: 'Stable' }
    )
    equivalent = PaperTrailDiff::RecordSnapshot.new(
      type: 'TrackedComment',
      id: 1,
      attributes: { body: 'Stable' }
    )
    changed = PaperTrailDiff::RecordSnapshot.new(
      type: 'TrackedComment',
      id: 1,
      attributes: { body: 'Changed' }
    )
    association = PaperTrailDiff::AssociationSnapshot.new(
      kind: :has_many,
      records: [record]
    )
    equivalent_association = PaperTrailDiff::AssociationSnapshot.new(
      kind: :has_many,
      records: [record]
    )

    expect(pool.record('comments', record)).to equal(record)
    expect(pool.record('comments', equivalent)).to equal(record)
    expect(pool.record('comments', changed)).to equal(changed)
    expect(pool.association('comments', association)).to equal(association)
    expect(pool.association('comments', equivalent_association)).to equal(association)
    expect(PaperTrailDiff::Engine.compare(record, record)).to be_empty
    expect(PaperTrailDiff::Engine.compare(nil, record).record_presence_change).not_to be_nil
  end

  it 'captures descendant activity through current state without a final root checkpoint' do
    graph = article_with_graph
    graph[:kept_comment].update!(body: 'Live activity comment')
    graph[:reply].update!(body: 'Live activity reply')

    steps = PaperTrailDiff.activity_timeline(
      graph[:article],
      from: graph[:before],
      to: graph[:article],
      associations: ['comments.replies']
    )
    reference = full_activity_timeline(
      graph[:article],
      from: graph[:before],
      to: graph[:article],
      associations: ['comments.replies']
    )
    changed = steps.reject { |step| step.diff.empty? }

    expect(steps.map { |step| step.diff.to_h }).to eq(reference.map { |step| step.diff.to_h })
    expect(changed.map { |step| step.from_boundary.item_type })
      .to eq(%w[TrackedComment TrackedReply])
    expect(changed.last.to_boundary.kind).to eq(:current)
    reply = changed.last.diff.associations.fetch('comments').changed
                   .first.associations.fetch('replies').changed.first
    expect(reply.attributes.fetch('body').to_h)
      .to eq(from: 'Nested before', to: 'Live activity reply')
  end

  it 'reports current-ended child additions and removals at their own boundaries' do
    graph = article_with_graph
    transient = graph[:article].comments.create!(body: 'Live transient')
    transient.destroy!

    changed = PaperTrailDiff.activity_timeline(
      graph[:article],
      from: graph[:before],
      to: graph[:article],
      associations: [:comments]
    ).reject { |step| step.diff.empty? }
    comments = changed.map { |step| step.diff.associations.fetch('comments') }

    expect(comments.map { |diff| diff.added.map(&:id) }).to eq([[transient.id], []])
    expect(comments.map { |diff| diff.removed.map(&:id) }).to eq([[], [transient.id]])
    expect(changed.last.to_boundary.kind).to eq(:current)
  end

  it 'rejects live-ended HABTM activity while retaining live endpoint comparison' do
    graph = article_with_graph

    expect do
      PaperTrailDiff.activity_timeline(
        graph[:article],
        from: graph[:before],
        to: graph[:article],
        associations: [:tags]
      )
    end.to raise_error(PaperTrailDiff::UnsupportedLiveActivityError, /HABTM/)
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

  it 'reports nested child additions and removals at their own activity boundaries' do
    graph = article_with_graph
    transient = graph[:kept_comment].replies.create!(body: 'Nested transient')
    transient.update!(body: 'Nested transient after')
    transient.destroy!
    after = boundary_for(graph[:article])

    optimized = PaperTrailDiff.activity_timeline(
      graph[:article],
      from: graph[:before],
      to: after,
      associations: ['comments.replies']
    )
    reference = full_activity_timeline(
      graph[:article],
      from: graph[:before],
      to: after,
      associations: ['comments.replies']
    )
    changed = optimized.reject { |step| step.diff.empty? }
    reply_diffs = changed.map do |step|
      step.diff.associations.fetch('comments').changed.first
          .associations.fetch('replies')
    end

    expect(optimized.map(&:to_h)).to eq(reference.map(&:to_h))
    expect(reply_diffs.map { |diff| diff.added.map(&:id) })
      .to eq([[transient.id], [], []])
    expect(reply_diffs.map { |diff| diff.removed.map(&:id) })
      .to eq([[], [], [transient.id]])
    expect(reply_diffs.fetch(1).changed.first.attributes).to have_key('body')
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

  it 'warns when association checkpoints synchronize version timestamps' do
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
    expect(report.warnings.first.path).to be_nil
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
