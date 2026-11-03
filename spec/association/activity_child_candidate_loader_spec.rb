# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/string_item_database'

ActiveRecord::Schema.define do
  create_table :child_loader_badges, force: true do |table|
    table.string :type
    table.string :label, null: false
    table.references :holder, polymorphic: true
    table.integer :sponsor_id
    table.timestamps null: false
  end
end

class ChildLoaderBadge < ActiveRecord::Base
  belongs_to :holder, polymorphic: true, optional: true
  # Another key to the same owners, which does not make a badge theirs.
  belongs_to :sponsor, class_name: 'PreparedDocument', optional: true
  has_paper_trail
end

class ChildLoaderPinnedBadge < ChildLoaderBadge
end

# The same table without STI, hiding some badges behind a default scope.
class ChildLoaderVisibleBadge < ActiveRecord::Base
  self.table_name = 'child_loader_badges'
  self.inheritance_column = :_no_sti
  default_scope { where.not(label: 'hidden') }
  belongs_to :holder, polymorphic: true, optional: true
  has_paper_trail
end

# A subclass owner: a polymorphic key names its base class, PreparedDocument.
class ChildLoaderDocument < PreparedDocument
  has_many :badges, class_name: 'ChildLoaderBadge', as: :holder
  has_many :pinned_badges, class_name: 'ChildLoaderPinnedBadge', as: :holder
  has_many :visible_badges, class_name: 'ChildLoaderVisibleBadge', as: :holder
end

RSpec.describe PaperTrailDiff::ActivityChildCandidateLoader do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    StringItemVersionAssociation.delete_all
    StringItemVersion.delete_all
    [ChildLoaderBadge, PreparedDocument, TrackedComment, TrackedArticle, TrackedAuthor,
     StringItemNote, StringItemPost].each(&:delete_all)
  end

  def loader(owner_class, owner_ids, association, start_at = nil)
    described_class.new(owner_class, owner_ids, owner_class.reflect_on_association(association),
                        start_at)
  end

  # The child ids of the rows, which are owner id, child id, time and event.
  def child_ids(owner_class, owner_ids, association)
    loader(owner_class, owner_ids, association).historical_rows.map { |row| row.fetch(1) }
  end

  def document(name = 'Board')
    ChildLoaderDocument.create!(name: name)
  end

  # PT-AT records a version's foreign keys after its change, so the latest
  # version before the start names the owner the child had at the start.
  it 'reads the version each child had at the start and every version after it' do
    board = document
    badge = ChildLoaderBadge.create!(label: 'Draft', holder: board)
    badge.update!(label: 'Kept')
    start = TrackedAuthor.create!(name: 'Marker').versions.last.created_at
    badge.update!(label: 'Final')
    kept, final = badge.versions.reorder(:id).last(2)

    expect(loader(ChildLoaderDocument, [board.id], :badges, start).historical_rows)
      .to contain_exactly([board.id, badge.id, kept.created_at, 'update'],
                          [board.id, badge.id, final.created_at, 'update'])
  end

  it "reads only the given owners' children, under the association's own key" do
    board, other = %w[Board Other].map { |name| document(name) }
    held = ChildLoaderBadge.create!(label: 'Held', holder: board)
    ChildLoaderBadge.create!(label: 'Elsewhere', holder: other)
    ChildLoaderBadge.create!(label: 'Sponsored', holder: other, sponsor: board)

    expect(child_ids(ChildLoaderDocument, [board.id], :badges)).to eq([held.id])
  end

  # A polymorphic key names the base class, and a plain belongs_to the class
  # it names, which may be the subclass. A row with no type is anyone's.
  it 'reads rows recorded under any name the owner goes by, or none' do
    board = document
    badges = %w[base own untyped blank foreign].to_h do |label|
      [label, ChildLoaderBadge.create!(label: label, holder: board)]
    end
    { 'own' => 'ChildLoaderDocument', 'untyped' => nil, 'blank' => '',
      'foreign' => 'TrackedArticle' }.each do |label, type|
      PaperTrail::VersionAssociation.joins(:version)
                                    .where(versions: { item_type: 'ChildLoaderBadge',
                                                       item_id: badges.fetch(label).id })
                                    .update_all(foreign_type: type)
    end

    expect(child_ids(ChildLoaderDocument, [board.id], :badges))
      .to match_array(badges.values_at('base', 'own', 'untyped', 'blank').map(&:id))
  end

  # A record can change type, so a plain badge may have been pinned within
  # the range; a model that only shares the table is not a badge.
  it "reads every version of the association's base class, which its subclass's carry" do
    board = document
    pinned = ChildLoaderPinnedBadge.create!(label: 'Pinned', holder: board)
    plain = ChildLoaderBadge.create!(label: 'Plain', holder: board)
    ChildLoaderVisibleBadge.create!(label: 'Another model', holder: board)

    expect(child_ids(ChildLoaderDocument, [board.id], :pinned_badges))
      .to contain_exactly(pinned.id, plain.id)
  end

  it "reads a child id stored as a string as the child key's type" do
    post = StringItemPost.create!(title: 'Post')
    note = post.notes.create!(body: 'Note')

    expect(child_ids(StringItemPost, [post.id], :notes)).to eq([note.id])
  end

  it 'reads the live children of the given owners, past the default scope, by owner type' do
    board, other = %w[Board Other].map { |name| document(name) }
    shown = ChildLoaderVisibleBadge.create!(label: 'shown', holder: board)
    hidden = ChildLoaderVisibleBadge.create!(label: 'hidden', holder: board)
    ChildLoaderVisibleBadge.create!(label: 'elsewhere', holder: other)
    ChildLoaderVisibleBadge.create!(label: 'same id', holder_type: 'TrackedArticle',
                                    holder_id: board.id)

    expect(loader(ChildLoaderDocument, [board.id], :visible_badges).current_pairs)
      .to contain_exactly([board.id, shown.id], [board.id, hidden.id])
  end

  it "reads the live rows of the association's base class, as history does" do
    board = document
    pinned = ChildLoaderPinnedBadge.create!(label: 'Pinned', holder: board)
    plain = ChildLoaderBadge.create!(label: 'Plain', holder: board)

    expect(loader(ChildLoaderDocument, [board.id], :pinned_badges).current_pairs)
      .to contain_exactly([board.id, pinned.id], [board.id, plain.id])
  end

  it 'reads the live children of a plain has_many' do
    article = TrackedArticle.create!(title: 'Article')
    comment = TrackedComment.create!(article: article, body: 'Comment')
    TrackedComment.create!(article: TrackedArticle.create!(title: 'Other'), body: 'Other')

    expect(loader(TrackedArticle, [article.id], :comments).current_pairs)
      .to eq([[article.id, comment.id]])
  end

  it 'reads nothing for a composite foreign key' do
    article = TrackedArticle.create!(title: 'Article')
    TrackedComment.create!(article: article, body: 'Comment')
    reflection = instance_double(ActiveRecord::Reflection::HasManyReflection,
                                 foreign_key: %w[article_id reviewer_id])
    composite = described_class.new(TrackedArticle, [article.id], reflection, nil)

    expect([composite.historical_rows, composite.current_pairs]).to eq([[], []])
  end
end
