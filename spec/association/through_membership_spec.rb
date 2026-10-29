# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :membership_authors, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :membership_posts, force: true do |table|
    table.string :title, null: false
    table.integer :author_id
    table.timestamps null: false
  end

  create_table :membership_notes, force: true do |table|
    table.string :body, null: false
    table.integer :post_id
    table.integer :reviewer_id
    table.timestamps null: false
  end
end

class MembershipAuthor < ActiveRecord::Base
  has_many :posts, class_name: 'MembershipPost', foreign_key: :author_id, inverse_of: :author
  has_many :notes, through: :posts
  has_many :note_reviewers, through: :notes, source: :reviewer
  has_paper_trail
end

class MembershipPost < ActiveRecord::Base
  belongs_to :author, class_name: 'MembershipAuthor', optional: true, inverse_of: :posts
  has_many :notes, class_name: 'MembershipNote', foreign_key: :post_id, inverse_of: :post
  has_paper_trail
end

class MembershipNote < ActiveRecord::Base
  belongs_to :post, class_name: 'MembershipPost', optional: true, inverse_of: :notes
  belongs_to :reviewer, class_name: 'MembershipAuthor', optional: true
  has_paper_trail
end

# An author's notes are the notes of the posts the author had, each read as it
# stood at the boundary: a note follows its post, and a post its author.
RSpec.describe 'A has_many :through whose source is a has_many' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [MembershipNote, MembershipPost, MembershipAuthor].each(&:delete_all)
  end

  let(:ada) { MembershipAuthor.create!(name: 'Ada') }
  let(:bea) { MembershipAuthor.create!(name: 'Bea') }

  # One version per author, saved together, at which the range starts or ends.
  def checkpoint(*authors)
    MembershipAuthor.transaction do
      authors.to_h do |author|
        fresh = MembershipAuthor.find(author.id)
        fresh.paper_trail.save_with_version
        [author.id, fresh.versions.reorder(:id).last]
      end
    end
  end

  def notes_change(diff, name = 'notes', attribute = 'body')
    association = diff.associations[name]
    return { added: [], removed: [], changed: [] } unless association

    { added: association.added.map { |note| note.attributes.fetch(attribute) },
      removed: association.removed.map { |note| note.attributes.fetch(attribute) },
      changed: association.changed.map { |change| change.attributes.transform_values(&:to_h) } }
  end

  def single(author, from, to, path = :notes)
    PaperTrailDiff.analyze(author, from: from.fetch(author.id), to: to.fetch(author.id),
                                   associations: [path]).diff
  end

  def empty
    { added: [], removed: [], changed: [] }
  end

  it 'moves a note from one author to the other with the post it moves to' do
    note = MembershipPost.create!(title: 'A', author: ada).notes.create!(body: 'note')
    other = MembershipPost.create!(title: 'B', author: bea)
    from = checkpoint(ada, bea)
    note.update!(post: other)
    to = checkpoint(ada, bea)

    expect(notes_change(single(ada, from, to))).to eq(empty.merge(removed: ['note']))
    expect(notes_change(single(bea, from, to))).to eq(empty.merge(added: ['note']))
  end

  it 'moves the notes of a post with it when the post changes author' do
    post = MembershipPost.create!(title: 'A', author: ada)
    %w[first second].each { |body| post.notes.create!(body: body) }
    bea
    from = checkpoint(ada, bea)
    post.update!(author: bea)
    to = checkpoint(ada, bea)

    expect(notes_change(single(ada, from, to))).to eq(empty.merge(removed: %w[first second]))
    expect(notes_change(single(bea, from, to))).to eq(empty.merge(added: %w[first second]))
  end

  it 'reports notes created, edited and destroyed under the posts' do
    post = MembershipPost.create!(title: 'A', author: ada)
    edited, gone = %w[edited gone].map { |body| post.notes.create!(body: body) }
    from = checkpoint(ada)
    edited.update!(body: 'edited again')
    gone.destroy!
    post.notes.create!(body: 'new')
    to = checkpoint(ada)

    expect(notes_change(single(ada, from, to)))
      .to eq(added: ['new'], removed: ['gone'],
             changed: [{ 'body' => { from: 'edited', to: 'edited again' } }])
  end

  it 'drops the notes of a post that is destroyed, though the notes stay' do
    post = MembershipPost.create!(title: 'A', author: ada)
    post.notes.create!(body: 'orphaned')
    from = checkpoint(ada)
    post.destroy!
    to = checkpoint(ada)

    expect(notes_change(single(ada, from, to))).to eq(empty.merge(removed: ['orphaned']))
  end

  # A boundary is the state before its transaction, so a post moved in the
  # same transaction as the author's version still belongs to the author there.
  it 'reads a post moved in the boundary version’s transaction as it was before' do
    post = MembershipPost.create!(title: 'A', author: ada)
    post.notes.create!(body: 'note')
    bea
    from = MembershipAuthor.transaction do
      ada.update!(name: 'Ada moved')
      post.update!(author: bea)
      ada.versions.reorder(:id).last
    end
    to = checkpoint(ada)

    expect(notes_change(single(ada, { ada.id => from }, to))).to eq(empty.merge(removed: ['note']))
  end

  it 'reports no change for a note that left and came back' do
    post = MembershipPost.create!(title: 'A', author: ada)
    note = post.notes.create!(body: 'note')
    other = MembershipPost.create!(title: 'B', author: bea)
    from = checkpoint(ada)
    note.update!(post: other)
    note.update!(post: post)
    to = checkpoint(ada)

    expect(notes_change(single(ada, from, to))).to eq(empty)
  end

  # Like any change saved without a version, a move PaperTrail never recorded
  # belongs to the note's last recorded change, here its creation.
  it 'places a move saved without a version at the note’s last recorded change' do
    post = MembershipPost.create!(title: 'A', author: ada)
    other = MembershipPost.create!(title: 'B', author: bea)
    from = checkpoint(ada, bea)
    note = post.notes.create!(body: 'note')
    to = checkpoint(ada, bea)
    note.update_columns(post_id: other.id)

    expect(notes_change(single(ada, from, to))).to eq(empty)
    expect(notes_change(single(bea, from, to))).to eq(empty.merge(added: ['note']))
  end

  it 'follows a through whose own through is a through' do
    post = MembershipPost.create!(title: 'A', author: ada)
    note = post.notes.create!(body: 'note', reviewer: bea)
    from = checkpoint(ada)
    note.update!(reviewer: nil)
    to = checkpoint(ada)

    expect(notes_change(single(ada, from, to, :note_reviewers), 'note_reviewers', 'name'))
      .to eq(empty.merge(removed: ['Bea']))
  end

  describe 'in a batch' do
    def batched(authors, window, **options)
      PaperTrailDiff.analyze_many(authors, within: window, associations: %i[notes note_reviewers],
                                           **options)
    end

    def separately(authors, window, **options)
      authors.to_h do |author|
        [PaperTrailDiff::Endpoint.identity(author),
         PaperTrailDiff.analyze(author, within: window, associations: %i[notes note_reviewers],
                                        **options)]
      end
    end

    # A current boundary records when each call read it, so steps compare by
    # the version they start at.
    def summary(analysis)
      steps = analysis.activity_timeline&.map do |step|
        [step.from_boundary.version_id, step.to_boundary.kind, step.diff.to_h]
      end
      [notes_change(analysis.diff), notes_change(analysis.diff, 'note_reviewers', 'name'), steps]
    end

    it 'matches each author analyzed alone, with or without activity' do
      post = MembershipPost.create!(title: 'A', author: ada)
      moved = post.notes.create!(body: 'moved', reviewer: bea)
      other = MembershipPost.create!(title: 'B', author: bea)
      kept = other.notes.create!(body: 'kept')
      start = checkpoint(ada, bea).values.first.created_at
      moved.update!(post: other, reviewer: nil)
      kept.update!(body: 'kept again')
      other.update!(author: ada)
      checkpoint(ada, bea)
      window = start..Time.now.utc

      summaries = ->(results) { results.transform_values { |analysis| summary(analysis) } }
      [{}, { activity: true }].each do |options|
        expect(summaries.call(batched([ada, bea], window, **options)))
          .to eq(summaries.call(separately([ada, bea], window, **options)))
      end
      diffs = batched([ada, bea], window).values.map(&:diff)
      expect(diffs.map { |diff| notes_change(diff) }).to eq(
        [{ added: ['kept again'], removed: [],
           changed: [{ 'post_id' => { from: post.id, to: other.id },
                       'reviewer_id' => { from: bea.id, to: nil } }] },
         empty.merge(removed: ['kept'])]
      )
      expect(diffs.map { |diff| notes_change(diff, 'note_reviewers', 'name') })
        .to eq([empty.merge(removed: ['Bea']), empty])
    end
  end
end
