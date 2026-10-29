# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :rank_shelves, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :rank_books, force: true do |table|
    table.string :title, null: false
    table.integer :rank
    table.timestamps null: false
  end

  create_table :rank_links, force: true do |table|
    table.integer :shelf_id
    table.integer :book_id
    table.boolean :hidden, null: false, default: false
    table.timestamps null: false
  end
end

class RankShelf < ActiveRecord::Base
  has_many :links, class_name: 'RankLink', foreign_key: :shelf_id
  has_many :first_links, -> { order(:id).limit(1) }, class_name: 'RankLink', foreign_key: :shelf_id
  has_many :later_links, -> { where(hidden: false).order(:id).offset(1) },
           class_name: 'RankLink', foreign_key: :shelf_id
  has_one :lead_link, -> { order(id: :desc) }, class_name: 'RankLink', foreign_key: :shelf_id
  # Each reads its part's conditions only, as Active Record does.
  has_many :first_link_books, through: :first_links, source: :book
  has_many :later_link_books, through: :later_links, source: :book
  has_many :lead_link_books, through: :lead_link, source: :book
  # A book linked twice fills two of the limit's rows.
  has_many :top_books, -> { order(:rank, :id).limit(2) }, through: :links, source: :book
  has_many :later_top_books, -> { order(rank: :desc, id: :asc).offset(1) },
           through: :later_links, source: :book
  has_paper_trail
end

class RankBook < ActiveRecord::Base
  has_paper_trail
end

class RankLink < ActiveRecord::Base
  belongs_to :shelf, class_name: 'RankShelf', optional: true
  belongs_to :book, class_name: 'RankBook', optional: true
  has_paper_trail
end

# A has_many through reads its parts' conditions but not their limit, offset
# or has_one cut, and ranks by its own order the rows its join yields. Each
# checkpoint here records what the association returned then, and history and
# a batched live read must reproduce it.
RSpec.describe 'A has_many through a ranked part, or ranked itself, over time' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [RankLink, RankBook, RankShelf].each(&:delete_all)
  end

  let(:paths) { %i[first_link_books later_link_books lead_link_books top_books later_top_books] }
  let(:checkpoints) { [] }

  def live(shelf)
    fresh = RankShelf.find(shelf.id)
    paths.to_h { |path| [path.to_s, fresh.public_send(path).map(&:id).uniq.sort] }
  end

  def checkpoint(*shelves)
    versions = RankShelf.transaction do
      shelves.to_h do |shelf|
        fresh = RankShelf.find(shelf.id)
        fresh.paper_trail.save_with_version
        [shelf.id, fresh.versions.reorder(:id).last]
      end
    end
    checkpoints << [versions, shelves.to_h { |shelf| [shelf.id, live(shelf)] }]
  end

  def members(snapshot)
    paths.to_h do |path|
      [path.to_s, snapshot.associations.fetch(path.to_s).records.map(&:id).sort]
    end
  end

  def link(shelf, book, **attributes)
    RankLink.create!(shelf: shelf, book: book, **attributes)
  end

  # The first shelf links one book twice.
  def seed(first, second)
    books = [3, nil, 1, 1].each_with_index.map do |rank, index|
      RankBook.create!(title: "book #{index}", rank: rank)
    end
    a, b, c, d = books
    first_link = link(first, b)
    [c, b, a].each { |book| link(first, book) }
    link(second, d)
    [first_link, *books]
  end

  # Duplicate links, ties in rank and NULLs, hides, moves and destroys.
  def history(first, second)
    first_link, a, b, c, d = seed(first, second)
    checkpoint(first, second)
    first_link.destroy!
    b.update!(rank: 0)
    link(second, a)
    checkpoint(first, second)
    RankLink.transaction do
      RankLink.where(book: c).find_each { |row| row.update!(hidden: true) }
      d.update!(rank: 4)
    end
    link(first, d)
    checkpoint(first, second)
    RankLink.find_by!(shelf: first, book: a).update!(shelf: second)
    c.update!(rank: nil)
    checkpoint(first, second)
  end

  def ranges
    checkpoints.each_cons(2).to_a + [[checkpoints.first, checkpoints.last]]
  end

  it 'reads each boundary as the association returned it' do
    shelves = [RankShelf.create!(name: 'first'), RankShelf.create!(name: 'second')]
    history(*shelves)

    ranges.each do |(from_versions, from_live), (to_versions, to_live)|
      shelves.each do |shelf|
        steps = PaperTrailDiff.activity_timeline(shelf, from: from_versions.fetch(shelf.id),
                                                        to: to_versions.fetch(shelf.id),
                                                        associations: paths, snapshots: true)
        expect([members(steps.first.from_snapshot), members(steps.last.to_snapshot)])
          .to eq([from_live.fetch(shelf.id), to_live.fetch(shelf.id)])
      end
    end
    expect(checkpoints.map(&:last).uniq.size).to eq(checkpoints.size)
  end

  def summary(analysis)
    steps = analysis.activity_timeline&.map do |step|
      [step.from_boundary.version_id, step.to_boundary.kind, step.diff.to_h]
    end
    [analysis.diff.to_h, steps]
  end

  it 'matches each shelf analyzed alone in a batch, without an expensive opt-in' do
    shelves = [RankShelf.create!(name: 'first'), RankShelf.create!(name: 'second')]
    history(*shelves)
    window = checkpoints.first.first.values.first.created_at..Time.now.utc

    [{}, { activity: true }].each do |options|
      batched = PaperTrailDiff.analyze_many(shelves, within: window, associations: paths,
                                                     **options)
      alone = shelves.map do |shelf|
        PaperTrailDiff.analyze(shelf, within: window, associations: paths, **options)
      end
      expect(batched.values.map { |analysis| summary(analysis) })
        .to eq(alone.map { |analysis| summary(analysis) })
    end
  end

  # The preloader would apply a part's limit or has_one cut to every owner
  # at once, so these load per record.
  it 'reads the current boundary of every shelf in a batch as each returns it' do
    shelves = [RankShelf.create!(name: 'first'), RankShelf.create!(name: 'second')]
    history(*shelves)
    from_versions, from_live = checkpoints.first

    compared = PaperTrailDiff.compare_many(
      shelves.map { |shelf| { from: from_versions.fetch(shelf.id), to: shelf } },
      associations: paths
    )
    shelves.zip(compared.values).each do |shelf, diff|
      before = from_live.fetch(shelf.id)
      after = live(shelf)
      paths.each do |path|
        change = diff.associations[path.to_s]
        ids = ->(records) { records.map(&:id).sort }
        expect([path, ids.call(change&.added.to_a), ids.call(change&.removed.to_a)])
          .to eq([path, after.fetch(path.to_s) - before.fetch(path.to_s),
                  before.fetch(path.to_s) - after.fetch(path.to_s)])
      end
    end
  end
end
