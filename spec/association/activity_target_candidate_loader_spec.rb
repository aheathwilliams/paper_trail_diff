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

  def loader(owner_class, owner_ids, association, start_at)
    reflection = owner_class.reflect_on_association(association)
    described_class.new(owner_class, owner_ids, reflection, start_at)
  end

  def historical(owner_class, owner_ids, association, start_at)
    loader(owner_class, owner_ids, association, start_at).historical_rows
  end

  def fields(found)
    found.map { |row| [row.owner_id, row.foreign_key_id, row.foreign_type, row.event] }
  end

  def version_of(record)
    record.versions.reorder(:id).last
  end

  # PT-AT records a version's foreign keys after its change, so the latest
  # version before the start names the target the owner had at the start.
  it 'reads the target at the start and each target set after it' do
    superseded, first, second, later = %w[Old Ann Bea Late].map do |name|
      TrackedAuthor.create!(name: name)
    end
    article = TrackedArticle.create!(title: 'Moving', author: superseded)
    article.update!(author: first)
    start = version_of(TrackedAuthor.create!(name: 'Marker')).created_at
    article.update!(author: second)
    article.update!(author: later)

    found = historical(TrackedArticle, [article.id], :author, start)

    expect(fields(found)).to contain_exactly(
      [article.id, first.id, 'TrackedAuthor', 'update'],
      [article.id, second.id, 'TrackedAuthor', 'update'],
      [article.id, later.id, 'TrackedAuthor', 'update']
    )
    expect(found.map(&:created_at)).to all(be_a(Time))
    expect(found).to all(be_frozen)
  end

  it 'reads the live target of each requested owner that has one' do
    author = TrackedAuthor.create!(name: 'Ann')
    article = TrackedArticle.create!(title: 'Live', author: author)
    loose = TrackedArticle.create!(title: 'No author')
    TrackedArticle.create!(title: 'Not requested', author: author)

    live = loader(TrackedArticle, [article.id, loose.id], :author, Time.now.utc).current_rows

    expect(fields(live)).to eq([[article.id, author.id, nil, nil]])
    expect(live.map(&:created_at)).to eq([nil])
    expect(live).to all(be_frozen)
  end

  it 'reads the owners Support::IDS_PER_STATEMENT to a statement' do
    stub_const('PaperTrailDiff::Support::IDS_PER_STATEMENT', 2)
    author = TrackedAuthor.create!(name: 'Ann')
    ids = Array.new(3) do |index|
      TrackedArticle.create!(title: "Article #{index}", author: author).id
    end
    statements = []
    count = ->(*, payload) { statements << payload[:sql] unless payload[:name] == 'SCHEMA' }

    historical, live = ActiveSupport::Notifications.subscribed(count, 'sql.active_record') do
      reader = loader(TrackedArticle, ids, :author, Time.now.utc - 3600)
      [reader.historical_rows, reader.current_rows]
    end

    expect(fields(historical))
      .to match_array(ids.map { |id| [id, author.id, 'TrackedAuthor', 'create'] })
    expect(fields(live)).to match_array(ids.map { |id| [id, author.id, nil, nil] })
    expect(statements.length).to eq(4)
  end

  # The comment and the profile share an id, and both record an `article_id`.
  it 'reads only the requested owners, their model, and the reflection key' do
    author = TrackedAuthor.create!(name: 'Ann')
    article = TrackedArticle.create!(title: 'Kept', author: author)
    TrackedArticle.create!(title: 'Other', author: author)
    start = version_of(article).created_at
    comment = TrackedComment.create!(id: 900, article: article, body: 'one', reviewer: author)
    TrackedProfile.create!(id: 900, article: TrackedArticle.create!(title: 'Profiled'), bio: 'b')

    expect(fields(historical(TrackedArticle, [article.id], :author, start)))
      .to eq([[article.id, author.id, 'TrackedAuthor', 'create']])
    expect(fields(historical(TrackedComment, [comment.id], :reviewer, start)))
      .to eq([[comment.id, author.id, 'TrackedAuthor', 'create']])
    expect(fields(historical(TrackedComment, [comment.id], :article, start)))
      .to eq([[comment.id, article.id, 'TrackedArticle', 'create']])
  end

  it 'reads a polymorphic key with its type from history and from the live row' do
    article = TrackedArticle.create!(title: 'Holder')
    sticker = TargetLoaderSticker.create!(label: 'one', holder: article)
    holder = loader(TargetLoaderSticker, [sticker.id], :holder, version_of(sticker).created_at)

    expect(fields(holder.historical_rows))
      .to eq([[sticker.id, article.id, 'TrackedArticle', 'create']])
    expect(fields(holder.current_rows)).to eq([[sticker.id, article.id, 'TrackedArticle', nil]])
  end

  it 'reads an STI owner under its base class name' do
    author = TrackedAuthor.create!(name: 'Sponsor')
    sticker = TargetLoaderSponsoredSticker.create!(label: 'sponsored', sponsor: author)
    start = version_of(sticker).created_at

    expect(fields(historical(TargetLoaderSponsoredSticker, [sticker.id], :sponsor, start)))
      .to eq([[sticker.id, author.id, 'TrackedAuthor', 'create']])
  end

  it 'reads the live target of owners of the base class and its subclasses alike' do
    article = TrackedArticle.create!(title: 'Holder')
    plain = TargetLoaderSticker.create!(label: 'plain', holder: article)
    sponsored = TargetLoaderSponsoredSticker.create!(label: 'sponsored', holder: article)

    live = loader(TargetLoaderSponsoredSticker, [plain.id, sponsored.id], :holder,
                  Time.now.utc).current_rows

    expect(fields(live)).to contain_exactly([plain.id, article.id, 'TrackedArticle', nil],
                                            [sponsored.id, article.id, 'TrackedArticle', nil])
  end

  it 'types owner ids read from a string item_id' do
    post = StringItemPost.create!(title: 'Post')
    note = StringItemNote.create!(post: post, body: 'one')
    start = note.versions.reorder(:id).last.created_at

    expect(fields(historical(StringItemNote, [note.id], :post, start)))
      .to eq([[note.id, post.id, 'StringItemPost', 'create']])
  end

  it 'reads nothing for a composite foreign key' do
    article = TrackedArticle.create!(title: 'Article', author: TrackedAuthor.create!(name: 'Ann'))
    reflection = instance_double(ActiveRecord::Reflection::BelongsToReflection,
                                 foreign_key: Class.new(Array).new(%w[author_id title]))
    composite = described_class.new(TrackedArticle, [article.id], reflection, Time.now.utc - 60)

    expect([composite.historical_rows, composite.current_rows]).to eq([[], []])
  end

  it 'reads the live target of an owner its default scope hides' do
    author = TrackedAuthor.create!(name: 'Ann')
    article = TargetLoaderHiddenArticle.create!(title: 'Hidden', author: author)

    live = loader(TargetLoaderHiddenArticle, [article.id], :author, Time.now.utc).current_rows

    expect(fields(live)).to eq([[article.id, author.id, nil, nil]])
  end

  it 'reads no live rows for an owner with a composite primary key' do
    author = TrackedAuthor.create!(name: 'Ann')
    article = TargetLoaderCompositeArticle.create!(title: 'Composite', author: author)

    expect(loader(TargetLoaderCompositeArticle, [[article.id.first, 'Composite']], :author,
                  Time.now.utc - 60).current_rows).to eq([])
  end
end
