# frozen_string_literal: true

require_relative '../support/normalizer_database'

RSpec.describe PaperTrailDiff::SnapshotNormalizer do
  before do
    [NormVersion, NormAuthor, NormPost, NormComment, NormCover, NormTag].each(&:delete_all)
  end

  let(:reifier) { instance_spy(PaperTrailDiff::HistoricalAssociationReifier) }

  def tree(*paths)
    PaperTrailDiff::AssociationTree.build(paths)
  end

  def normalizer(tree, all: [], paths: {})
    described_class.new(
      tree: tree, ignore_policy: PaperTrailDiff::IgnorePolicy.new(all: all, paths: paths),
      traversal: PaperTrailDiff::AssociationTraversal.new(tree)
    )
  end

  def snapshot(record, *paths, **ignore)
    normalizer(tree(*paths), **ignore).call(record, reifier: reifier)
  end

  def post_with_comments
    post = NormPost.create!(title: 'Post')
    post.comments.create!(body: 'first')
    post.comments.create!(body: 'second')
    post
  end

  describe 'a root record' do
    it 'leaves out its primary key and the columns PaperTrail never records' do
      post = NormPost.create!(title: 'Post', views: 5, secret: 'shh')

      result = snapshot(post)

      expect(result).to have_attributes(type: 'NormPost', id: post.id, associations: {})
      expect(result.attributes.keys).to contain_exactly('title', 'author_id', 'published_at')
    end

    it 'leaves out ignored attributes' do
      post = NormPost.create!(title: 'Post')

      expect(snapshot(post, all: ['title']).attributes.keys)
        .to contain_exactly('author_id', 'published_at')
      expect(snapshot(post, paths: { '$' => ['author_id'] }).attributes.keys)
        .to contain_exactly('title', 'published_at')
    end

    it 'keeps times to the precision JSON history stores' do
      post = NormPost.create!(title: 'Post', published_at: Time.utc(2030, 1, 1, 0, 0, 0, 123_456))
      original = PaperTrail.serializer
      PaperTrail.serializer = PaperTrail::Serializers::JSON

      expect(snapshot(post).attributes.fetch('published_at').nsec).to eq(123_000_000)
    ensure
      PaperTrail.serializer = original
    end

    it 'is nothing when there is no record' do
      expect(snapshot(nil, 'comments.post')).to be_nil
    end

    it 'leaves out every column of a composite primary key' do
      tag = NormTag.create!(post_id: 4, name: 'ruby', colour: 'red')

      result = snapshot(tag)

      expect(result.id).to eq([4, 'ruby'])
      expect(result.attributes).to eq('colour' => 'red')
    end

    it 'is a new object each time, while unchanged associations are reused' do
      post = post_with_comments
      NormCover.create!(caption: 'Cover', owner: post)
      normalizer = normalizer(tree('comments', 'cover'))

      first = normalizer.call(post, reifier: reifier)
      second = normalizer.call(NormPost.find(post.id), reifier: reifier)

      expect(second).not_to equal(first)
      expect(second.associations).to eq(first.associations)
      second.associations.each do |name, association|
        expect(association).to equal(first.associations.fetch(name))
      end
    end

    it 'reuses a record reached by two paths' do
      post = post_with_comments
      first_comment, second_comment = post.comments.to_a
      first_comment.update!(subject: second_comment)
      normalizer = normalizer(tree('comments.subject'))

      first = normalizer.call(post, reifier: reifier)
      second = normalizer.call(NormPost.find(post.id), reifier: reifier)

      expect(second.associations.fetch('comments')).to equal(first.associations.fetch('comments'))
    end
  end

  describe 'a selected belongs_to' do
    it 'replaces the foreign key and polymorphic type with the association' do
      author = NormAuthor.create!(name: 'Ada')
      post = NormPost.create!(title: 'Post', author: author)
      comment = NormComment.create!(body: 'Hi', post: post, subject: author)

      result = snapshot(comment, 'post', 'subject')

      expect(result.attributes.keys).to contain_exactly('body', 'type', 'parent_id')
      expect(result.associations.keys).to eq(%w[post subject])
      expect(result.associations.fetch('post')).to have_attributes(kind: :belongs_to)
      expect(result.associations.fetch('post').records.map(&:id)).to eq([post.id])
      expect(result.associations.fetch('subject').records.map(&:type)).to eq(['NormAuthor'])
    end

    it 'is empty when nothing is assigned' do
      comment = NormComment.create!(body: 'Hi')

      expect(snapshot(comment, 'post').associations.fetch('post').records).to eq([])
    end

    it 'leaves a column a has_many shares with it alone' do
      parent = NormComment.create!(body: 'Parent')
      comment = NormComment.create!(body: 'Child', parent: parent)

      expect(snapshot(comment, 'replies').attributes.keys).to include('parent_id')
      expect(snapshot(comment, 'parent').attributes.keys).not_to include('parent_id')
    end
  end

  describe 'a selected has_many' do
    it 'lists the children in order, without the key that points back' do
      post = post_with_comments

      comments = snapshot(post, 'comments').associations.fetch('comments')

      expect(comments.kind).to eq(:has_many)
      expect(comments.records.map { |record| record.attributes.fetch('body') })
        .to eq(%w[first second])
      expect(comments.records.map { |record| record.attributes.keys })
        .to all(contain_exactly('body', 'type', 'subject_type', 'subject_id', 'parent_id'))
    end

    it 'skips a member a reified history could not rebuild' do
      post = post_with_comments
      kept = post.comments.first
      post.define_singleton_method(:comments) { [nil, kept] }

      records = snapshot(post, 'comments').associations.fetch('comments').records

      expect(records.map(&:id)).to eq([kept.id])
    end

    it 'applies ignore rules for the children path' do
      post = post_with_comments

      result = snapshot(post, 'comments', paths: { 'comments' => ['body'] })
      comments = result.associations.fetch('comments')

      expect(comments.records.map { |record| record.attributes.keys })
        .to all(contain_exactly('type', 'subject_type', 'subject_id', 'parent_id'))
    end

    it 'reifies children only when their own associations are selected' do
      post = post_with_comments

      snapshot(post, 'comments')
      expect(reifier).not_to have_received(:reify)

      snapshot(post, 'comments.post')
      expect(reifier).to have_received(:reify)
        .with(an_instance_of(NormComment), [NormComment.reflect_on_association(:post)]).twice
    end

    it 'reifies all the way down a selected path' do
      post = post_with_comments

      snapshot(post, 'comments.post.comments')

      expect(reifier).to have_received(:reify)
        .with(an_instance_of(NormPost), [NormPost.reflect_on_association(:comments)])
        .at_least(:once)
    end

    it 'reads each child class own associations' do
      post = NormPost.create!(title: 'Post')
      post.comments.create!(body: 'comment', subject_id: 7)
      NormReply.create!(body: 'reply', post_id: post.id, subject_id: post.id)

      records = snapshot(post, 'comments.post').associations.fetch('comments').records

      expect(records.map(&:type)).to eq(%w[NormComment NormReply])
      expect(records.map { |record| record.attributes.keys.sort }).to eq(
        [%w[body parent_id subject_id subject_type type], %w[body parent_id subject_type type]]
      )
    end
  end

  describe 'a selected has_one' do
    it 'holds the one record, without the polymorphic key that points back' do
      post = NormPost.create!(title: 'Post')
      NormCover.create!(caption: 'Cover', owner: post)

      cover = snapshot(post, 'cover').associations.fetch('cover')

      expect(cover.kind).to eq(:has_one)
      expect(cover.records.map { |record| record.attributes.keys }).to eq([['caption']])
      expect(snapshot(NormPost.create!(title: 'Bare'), 'cover').associations.fetch('cover').records)
        .to eq([])
    end
  end

  describe '#call_child' do
    let(:comments_tree) { tree('comments.post') }
    let(:incoming) { NormPost.reflect_on_association(:comments) }

    def child(normalizer, record, tree)
      normalizer.call_child(record, tree: tree.child('comments'), path: 'comments',
                                    incoming: incoming, reifier: reifier)
    end

    it 'normalizes one child of a selected branch, reifying its own associations' do
      comment = post_with_comments.comments.first
      normalizer = normalizer(comments_tree)

      result = child(normalizer, comment, comments_tree)

      expect(result.attributes.keys)
        .to contain_exactly('body', 'type', 'subject_type', 'subject_id', 'parent_id')
      expect(result.associations.keys).to eq(['post'])
      expect(child(normalizer, comment, comments_tree)).to equal(result)
      expect(reifier).to have_received(:reify)
        .with(comment, [NormComment.reflect_on_association(:post)]).twice
    end

    it 'skips reifying when the child has no selected associations' do
      leaf = tree('comments')
      comment = post_with_comments.comments.first

      result = child(normalizer(leaf), comment, leaf)

      expect(result.associations).to eq({})
      expect(result.attributes.keys).not_to include('post_id')
      expect(reifier).not_to have_received(:reify)
    end

    it 'passes the reifier down a selected path' do
      deep = tree('comments.post.comments')
      comment = post_with_comments.comments.first

      child(normalizer(deep), comment, deep)

      expect(reifier).to have_received(:reify)
        .with(comment.post, [NormPost.reflect_on_association(:comments)])
    end

    it 'is nothing when there is no record' do
      expect(child(normalizer(comments_tree), nil, comments_tree)).to be_nil
    end
  end

  describe '#attributes_for' do
    it 'normalizes attributes without loading associations' do
      post = NormPost.find(post_with_comments.id)

      comments = tree('comments')
      attributes = normalizer(comments).attributes_for(post, tree: comments, path: '')

      expect(attributes.keys).to contain_exactly('title', 'author_id', 'published_at')
      expect(post.association(:comments)).not_to be_loaded
    end

    it 'leaves out the foreign keys of selected belongs_to associations' do
      post = NormPost.create!(title: 'Post')

      attributes = normalizer(tree('author')).attributes_for(post, tree: tree('author'), path: '')

      expect(attributes.keys).to contain_exactly('title', 'published_at')
    end

    it 'reads a prepared state the same way' do
      post = NormPost.create!(title: 'Post', views: 3)
      state = PaperTrailDiff::PreparedRecordState.from_attributes(NormPost, post.attributes)

      attributes = normalizer(tree).attributes_for(state, tree: tree, path: '')

      expect(attributes).to eq(snapshot(post).attributes)
    end
  end

  describe '#from_state' do
    let(:comment) { post_with_comments.comments.first }
    let(:state) { PaperTrailDiff::PreparedRecordState.from_attributes(NormComment, comment.attributes) }
    let(:incoming) { NormPost.reflect_on_association(:comments) }

    it 'builds the snapshot an Active Record child would give' do
      deep = tree('comments.post')
      branch = deep.child('comments')
      expected = normalizer(deep).call_child(
        comment, tree: branch, path: 'comments', incoming: incoming, reifier: reifier
      )
      fresh = normalizer(deep)

      result = fresh.from_state(state, tree: branch, path: 'comments', incoming: incoming)

      expect(result)
        .to have_attributes(type: expected.type, id: expected.id, attributes: expected.attributes)
      expect(fresh.from_state(state, tree: branch, path: 'comments')).to equal(result)
    end

    it 'keeps one held snapshot per path' do
      normalizer = normalizer(tree)
      first = normalizer.from_state(state, tree: tree, path: 'comments', incoming: incoming)
      normalizer.from_state(state, tree: tree, path: 'loose')

      expect(first.attributes.keys).not_to include('post_id')
      expect(normalizer.from_state(state, tree: tree, path: 'comments')).to equal(first)
    end

    it 'reads a composite key the way a live record does' do
      tag = NormTag.create!(post_id: 4, name: 'ruby', colour: 'red')
      tag_state = PaperTrailDiff::PreparedRecordState.from_attributes(NormTag, tag.attributes)

      expect(normalizer(tree).from_state(tag_state, tree: tree, path: '').id).to eq(tag.id)
    end

    it 'names the full path of an unknown association' do
      expect { normalizer(tree).from_state(state, tree: tree('bogus'), path: 'comments') }
        .to raise_error(PaperTrailDiff::UnknownAssociationError,
                        'unknown association: comments.bogus')
    end

    it 'keeps the associations it is given, and pools only below the root' do
      association = PaperTrailDiff::AssociationSnapshot.new(kind: :belongs_to, records: [])
      normalizer = normalizer(tree)

      associations = { 'post' => association }
      root = normalizer.from_state(state, tree: tree, path: '', associations: associations)
      again = normalizer.from_state(state, tree: tree, path: '', associations: associations)

      expect(root.associations).to eq('post' => association)
      expect(root.id).to eq(comment.id)
      expect(again).not_to equal(root)
      expect(normalizer.from_state(state, tree: tree, path: 'comments')).to equal(
        normalizer.from_state(state, tree: tree, path: 'comments')
      )
    end

    it 'keeps the key that points back when nothing says it is structural' do
      result = normalizer(tree).from_state(state, tree: tree, path: 'loose')

      expect(result.attributes.keys).to include('post_id')
    end
  end
end
