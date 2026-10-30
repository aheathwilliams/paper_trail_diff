# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :rank_lists, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :rank_items, force: true do |table|
    table.string :title, null: false
    table.integer :list_id
    table.integer :position
    table.boolean :pinned, null: false, default: false
    table.boolean :hidden, null: false, default: false
    table.datetime :seen_at
    table.date :due_on
    table.timestamps null: false
  end
end

class RankList < ActiveRecord::Base
  # `position` holds NULL, which each adapter sorts in its own place.
  has_many :top_items, -> { order(:position, :id).limit(2) }, class_name: 'RankItem',
                                                              foreign_key: :list_id
  has_many :bottom_items, -> { order(position: :desc, id: :desc).limit(2) },
           class_name: 'RankItem', foreign_key: :list_id
  has_many :later_items, -> { where(hidden: false).order(:id).offset(1) },
           class_name: 'RankItem', foreign_key: :list_id
  has_many :paged_items, -> { order(:pinned, :id).limit(2).offset(1) },
           class_name: 'RankItem', foreign_key: :list_id
  has_one :lead_item, -> { order(pinned: :desc, position: :asc, id: :asc) },
          class_name: 'RankItem', foreign_key: :list_id
  has_one :second_item, -> { order(:id).offset(1) }, class_name: 'RankItem', foreign_key: :list_id
  # Times a microsecond apart, as history keeps them, and dates.
  has_many :recent_items, -> { order(seen_at: :desc, id: :desc).limit(2) },
           class_name: 'RankItem', foreign_key: :list_id
  has_one :due_item, -> { order(:due_on, :id) }, class_name: 'RankItem', foreign_key: :list_id
  # Kept on the record path: a string order, an order with ties, and a through.
  has_many :titled_items, -> { order(:title, :id).limit(1) }, class_name: 'RankItem',
                                                              foreign_key: :list_id
  has_many :tied_items, -> { order(:position).limit(1) }, class_name: 'RankItem',
                                                          foreign_key: :list_id
  has_paper_trail
end

class RankItem < ActiveRecord::Base
  belongs_to :list, class_name: 'RankList', optional: true
  has_paper_trail
end

# A limited, offset or ordered has_one association's members at a boundary are
# the records its own query would have returned then. Each checkpoint here
# records that query's result, and history must reproduce it.
RSpec.describe 'A ranked association over time' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [RankItem, RankList].each(&:delete_all)
  end

  let(:paths) do
    %i[top_items bottom_items later_items paged_items lead_item second_item recent_items due_item]
  end
  let(:collections) { %i[top_items bottom_items later_items paged_items recent_items] }
  let(:at) { Time.utc(2026, 1, 1, 12) }
  let(:day) { Date.new(2026, 1, 1) }
  let(:checkpoints) { [] }

  # One version per list, saved together, with each association's live members
  # in the order a snapshot lists them, by ID.
  def checkpoint(*lists)
    versions = RankList.transaction do
      lists.to_h do |list|
        fresh = RankList.find(list.id)
        fresh.paper_trail.save_with_version
        [list.id, fresh.versions.reorder(:id).last]
      end
    end
    live = lists.to_h do |list|
      fresh = RankList.find(list.id)
      [list.id, paths.to_h { |path| [path.to_s, Array(fresh.public_send(path)).map(&:id).sort] }]
    end
    checkpoints << [versions, live]
  end

  def members(snapshot)
    paths.to_h do |path|
      [path.to_s, snapshot.associations.fetch(path.to_s).records.map(&:id)]
    end
  end

  def item(list, title, **attributes)
    RankItem.create!(list: list, title: title, **attributes)
  end

  def seed(list)
    [item(list, 'a', position: 2, seen_at: microseconds(1), due_on: day + 2),
     item(list, 'b'), item(list, 'c', position: 1, seen_at: microseconds(2), due_on: day),
     item(list, 'd', position: 2, pinned: true, seen_at: at, due_on: day + 2)]
  end

  def microseconds(count)
    at + Rational(count, 1_000_000)
  end

  # Ties in `position` and NULLs, moves, hides, destroys and new records.
  def history(first, second)
    a, b, c, d = seed(first)
    checkpoint(first, second)
    b.update!(position: 0, seen_at: microseconds(3))
    item(first, 'e', position: 1, seen_at: microseconds(2), due_on: day)
    checkpoint(first, second)
    RankItem.transaction do
      c.update!(position: nil, hidden: true, seen_at: nil)
      d.update!(pinned: false, due_on: day - 1)
    end
    a.destroy!
    checkpoint(first, second)
    b.update!(list: second)
    item(second, 'f', pinned: true, seen_at: microseconds(4), due_on: day - 2)
    c.update!(hidden: false, position: 3, due_on: day + 5)
    checkpoint(first, second)
  end

  def ranges
    checkpoints.each_cons(2).to_a + [[checkpoints.first, checkpoints.last]]
  end

  it 'reads each boundary with the members the association’s own query returned' do
    lists = [RankList.create!(name: 'first'), RankList.create!(name: 'second')]
    history(*lists)

    ranges.each do |(from_versions, from_live), (to_versions, to_live)|
      lists.each do |list|
        steps = PaperTrailDiff.activity_timeline(list, from: from_versions.fetch(list.id),
                                                       to: to_versions.fetch(list.id),
                                                       associations: paths, snapshots: true)
        expect([members(steps.first.from_snapshot), members(steps.last.to_snapshot)])
          .to eq([from_live.fetch(list.id), to_live.fetch(list.id)])
      end
    end
  end

  it 'adds and removes records as the ranking moves them in and out' do
    lists = [RankList.create!(name: 'first'), RankList.create!(name: 'second')]
    history(*lists)

    ranges.each do |(from_versions, from_live), (to_versions, to_live)|
      lists.each do |list|
        diff = PaperTrailDiff.compare(from_versions.fetch(list.id), to_versions.fetch(list.id),
                                      associations: paths)
        collections.each do |path|
          before = from_live.fetch(list.id).fetch(path.to_s)
          after = to_live.fetch(list.id).fetch(path.to_s)
          change = diff.associations[path.to_s]
          ids = ->(records) { records.map(&:id) }
          expect([ids.call(change&.added.to_a).sort, ids.call(change&.removed.to_a).sort])
            .to eq([(after - before).sort, (before - after).sort])
        end
      end
    end
  end

  # A current boundary records when each call read it, so steps compare by
  # the version they start at.
  def summary(analysis)
    steps = analysis.activity_timeline&.map do |step|
      [step.from_boundary.version_id, step.to_boundary.kind, step.diff.to_h]
    end
    [analysis.diff.to_h, steps]
  end

  it 'matches each list analyzed alone in a batch, without an expensive opt-in' do
    lists = [RankList.create!(name: 'first'), RankList.create!(name: 'second')]
    history(*lists)
    window = checkpoints.first.first.values.first.created_at..Time.now.utc

    [{}, { activity: true }].each do |options|
      batched = PaperTrailDiff.analyze_many(lists, within: window, associations: paths, **options)
      alone = lists.map do |list|
        PaperTrailDiff.analyze(list, within: window, associations: paths, **options)
      end
      expect(batched.values.map { |analysis| summary(analysis) })
        .to eq(alone.map { |analysis| summary(analysis) })
    end
    (from_versions, from_live), (to_versions, to_live) = ranges.last
    compared = PaperTrailDiff.compare_many(
      lists.map { |list| { from: from_versions.fetch(list.id), to: to_versions.fetch(list.id) } },
      associations: paths
    )
    expect(compared.values.map(&:to_h)).to eq(lists.map do |list|
      PaperTrailDiff.compare(from_versions.fetch(list.id), to_versions.fetch(list.id),
                             associations: paths).to_h
    end)
    expect(from_live).not_to eq(to_live)
  end

  it 'reports a step only where the ranking changed' do
    list = RankList.create!(name: 'first')
    first = item(list, 'first', position: 1)
    item(list, 'second', position: 2)
    start = checkpoint(list).last.first.fetch(list.id).created_at
    item(list, 'third', position: 3)
    first.update!(position: 4)
    entered = first.versions.reorder(:id).last

    steps = PaperTrailDiff.analyze(list, within: start..Time.now.utc, associations: [:top_items],
                                         activity: true).activity_timeline.reject(&:empty?)
    expect(steps.map { |step| step.source_boundary.version_id }).to eq([entered.id])
    change = steps.first.diff.associations.fetch('top_items')
    titles = [change.added, change.removed].map do |records|
      records.map { |record| record.attributes.fetch('title') }
    end
    expect(titles).to eq([['third'], ['first']])
  end

  it 'keeps a string order and an order with ties off the batch path' do
    list = RankList.create!(name: 'first')
    window = (Time.now.utc - 60)..Time.now.utc
    %i[titled_items tied_items].each do |path|
      expect { PaperTrailDiff.analyze_many([list], within: window, associations: [path]) }
        .to raise_error(PaperTrailDiff::UnsupportedBatchPathError, /#{path}/)
    end
  end
end
