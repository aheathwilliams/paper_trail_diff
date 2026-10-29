# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/string_item_database'

ActiveRecord::Schema.define do
  create_table :target_loader_stickers, force: true do |table|
    table.string :type
    table.string :label, null: false
    table.integer :sponsor_id
    table.references :holder, polymorphic: true
    table.timestamps null: false
  end
end

class TargetLoaderSticker < ActiveRecord::Base
  belongs_to :holder, polymorphic: true, optional: true
  has_paper_trail
end

class TargetLoaderSponsoredSticker < TargetLoaderSticker
  belongs_to :sponsor, class_name: 'TrackedAuthor', optional: true
end

# Hides some articles, so the live read has to look past the default scope.
class TargetLoaderHiddenArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  default_scope { where.not(title: 'Hidden') }
  belongs_to :author, class_name: 'TrackedAuthor', optional: true
  has_paper_trail
end

# Only primary_key is read on this path, so it reuses the articles table.
class TargetLoaderCompositeArticle < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  self.primary_key = %i[id title]
  belongs_to :author, class_name: 'TrackedAuthor', optional: true
  has_paper_trail
end

RSpec.describe PaperTrailDiff::ActivityTargetCandidateLoader do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    StringItemVersionAssociation.delete_all
    StringItemVersion.delete_all
    [TrackedComment, TrackedProfile, TrackedArticle, TrackedAuthor, TargetLoaderSticker,
     StringItemNote, StringItemPost].each(&:delete_all)
  end

  def rows(owner_class, owner_ids, association, range)
    reflection = owner_class.reflect_on_association(association)
    described_class.new(owner_class, owner_ids, reflection, range).call
  end

  def fields(found)
    found.map { |row| [row.owner_id, row.foreign_key_id, row.foreign_type, row.event] }
  end

  def version_of(record)
    record.versions.reorder(:id).last
  end

  # PT-AT records a version's foreign keys after its change, so the version
  # that closes the range names the author the article moves to after it.
  it 'reads the target when the range opened and each target set inside it' do
    superseded, first, second, closing, after = %w[Old Ann Bea Cy Late].map do |name|
      TrackedAuthor.create!(name: name)
    end
    article = TrackedArticle.create!(title: 'Moving', author: superseded)
    article.update!(author: first)
    start = version_of(TrackedAuthor.create!(name: 'Marker'))
    article.update!(author: second)
    article.update!(author: closing)
    finish = version_of(article)
    article.update!(author: after)

    range = PaperTrailDiff::ActivityRange.new(start, finish)
    found = rows(TrackedArticle, [article.id], :author, range)
    # The prepared index reads these directly, so they stop at the range end.
    historical = described_class.new(TrackedArticle, [article.id],
                                     TrackedArticle.reflect_on_association(:author), range)
                                .historical_rows

    expect(fields(found)).to contain_exactly(
      [article.id, first.id, 'TrackedAuthor', 'update'],
      [article.id, second.id, 'TrackedAuthor', 'update']
    )
    expect(historical.map(&:foreign_key_id)).not_to include(after.id)
    expect(found.map(&:created_at)).to all(be_a(Time))
    expect(found).to all(be_frozen)
  end

  it 'adds the live target only for a range that ends at the current record' do
    author = TrackedAuthor.create!(name: 'Ann')
    article = TrackedArticle.create!(title: 'Live', author: author)
    loose = TrackedArticle.create!(title: 'No author')
    TrackedArticle.create!(title: 'Not requested', author: author)
    start = version_of(article)
    historical = PaperTrailDiff::ActivityRange.new(start, start)
    current = PaperTrailDiff::ActivityRange.new(start, Time.now.utc)

    live = rows(TrackedArticle, [article.id, loose.id], :author, current)
    expected = [article.id, author.id, nil, nil]

    expect(fields(rows(TrackedArticle, [article.id, loose.id], :author, historical)))
      .not_to include(expected)
    expect(fields(live)).to include(expected)
    expect(live.select { |row| row.event.nil? }.map(&:owner_id)).to eq([article.id])
    expect(live.last.created_at).to be_nil
  end

  # The comment and the profile share an id, and both record an `article_id`.
  it 'reads only the requested owners, their model, and the reflection key' do
    author = TrackedAuthor.create!(name: 'Ann')
    article = TrackedArticle.create!(title: 'Kept', author: author)
    TrackedArticle.create!(title: 'Other', author: author)
    start = version_of(article)
    comment = TrackedComment.create!(id: 900, article: article, body: 'one', reviewer: author)
    TrackedProfile.create!(id: 900, article: TrackedArticle.create!(title: 'Profiled'), bio: 'b')
    range = PaperTrailDiff::ActivityRange.new(start, version_of(TrackedAuthor.create!(name: 'End')))

    expect(fields(rows(TrackedArticle, [article.id], :author, range)))
      .to eq([[article.id, author.id, 'TrackedAuthor', 'create']])
    expect(fields(rows(TrackedComment, [comment.id], :reviewer, range)))
      .to eq([[comment.id, author.id, 'TrackedAuthor', 'create']])
    expect(fields(rows(TrackedComment, [comment.id], :article, range)))
      .to eq([[comment.id, article.id, 'TrackedArticle', 'create']])
  end

  it 'reads a polymorphic key with its type from history and from the live row' do
    article = TrackedArticle.create!(title: 'Holder')
    sticker = TargetLoaderSticker.create!(label: 'one', holder: article)
    start = version_of(sticker)
    range = PaperTrailDiff::ActivityRange.new(start, Time.now.utc)

    expect(fields(rows(TargetLoaderSticker, [sticker.id], :holder, range))).to contain_exactly(
      [sticker.id, article.id, 'TrackedArticle', 'create'],
      [sticker.id, article.id, 'TrackedArticle', nil]
    )
  end

  it 'reads an STI owner under its base class name' do
    author = TrackedAuthor.create!(name: 'Sponsor')
    sticker = TargetLoaderSponsoredSticker.create!(label: 'sponsored', sponsor: author)
    start = version_of(sticker)
    finish = version_of(TrackedAuthor.create!(name: 'End'))

    expect(fields(rows(TargetLoaderSponsoredSticker, [sticker.id], :sponsor,
                       PaperTrailDiff::ActivityRange.new(start, finish))))
      .to eq([[sticker.id, author.id, 'TrackedAuthor', 'create']])
  end

  it 'reads the live target of owners of the base class and its subclasses alike' do
    article = TrackedArticle.create!(title: 'Holder')
    plain = TargetLoaderSticker.create!(label: 'plain', holder: article)
    sponsored = TargetLoaderSponsoredSticker.create!(label: 'sponsored', holder: article)
    range = PaperTrailDiff::ActivityRange.new(Time.now.utc, Time.now.utc)

    live = rows(TargetLoaderSponsoredSticker, [plain.id, sponsored.id], :holder, range)
           .select { |row| row.event.nil? }

    expect(fields(live)).to contain_exactly([plain.id, article.id, 'TrackedArticle', nil],
                                            [sponsored.id, article.id, 'TrackedArticle', nil])
  end

  it 'types owner ids read from a string item_id' do
    post = StringItemPost.create!(title: 'Post')
    note = StringItemNote.create!(post: post, body: 'one')
    start = note.versions.reorder(:id).last
    finish = StringItemPost.create!(title: 'End').versions.reorder(:id).last
    range = PaperTrailDiff::ActivityRange.new(start, finish)

    expect(fields(rows(StringItemNote, [note.id], :post, range)))
      .to eq([[note.id, post.id, 'StringItemPost', 'create']])
  end

  it 'reads nothing for a composite foreign key' do
    article = TrackedArticle.create!(title: 'Article', author: TrackedAuthor.create!(name: 'Ann'))
    reflection = instance_double(ActiveRecord::Reflection::BelongsToReflection,
                                 foreign_key: Class.new(Array).new(%w[author_id title]))
    range = PaperTrailDiff::ActivityRange.new(Time.now.utc - 60, Time.now.utc)
    loader = described_class.new(TrackedArticle, [article.id], reflection, range)

    expect(loader.call).to eq([])
  end

  it 'reads the live target of an owner its default scope hides' do
    author = TrackedAuthor.create!(name: 'Ann')
    article = TargetLoaderHiddenArticle.create!(title: 'Hidden', author: author)
    range = PaperTrailDiff::ActivityRange.new(Time.now.utc, Time.now.utc)

    live = rows(TargetLoaderHiddenArticle, [article.id], :author, range).select do |row|
      row.event.nil?
    end

    expect(fields(live)).to eq([[article.id, author.id, nil, nil]])
  end

  it 'reads no live rows for an owner with a composite primary key' do
    author = TrackedAuthor.create!(name: 'Ann')
    article = TargetLoaderCompositeArticle.create!(title: 'Composite', author: author)
    range = PaperTrailDiff::ActivityRange.new(Time.now.utc - 60, Time.now.utc)

    expect(rows(TargetLoaderCompositeArticle, [[article.id.first, 'Composite']], :author, range)
             .select { |row| row.event.nil? }).to eq([])
  end
end
