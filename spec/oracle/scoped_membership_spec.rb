# frozen_string_literal: true

require_relative '../support/oracle'

ActiveRecord::Schema.define do
  create_table :oracle_posts, force: true do |table|
    table.string :title
    table.timestamps
  end

  create_table :oracle_notes, force: true do |table|
    table.integer :post_id
    table.integer :position
    table.boolean :hidden
    table.integer :status, default: 0
    table.string :body
    table.datetime :deleted_at
    table.timestamps
  end
end

class OracleNote < ActiveRecord::Base
  enum :status, { draft: 0, live: 1, gone: 2 }
  belongs_to :post, class_name: 'OraclePost', optional: true
  has_paper_trail
end

# Every scope here can be read from stored attributes, so membership is
# rebuilt from history rather than from PT-AT. Records move in and out of each
# scope as their values change.
class OraclePost < ActiveRecord::Base
  notes = { class_name: 'OracleNote', foreign_key: :post_id }
  has_many :notes, **notes
  has_many :visible_notes, -> { where(hidden: false) }, **notes
  has_many :not_hidden_notes, -> { where.not(hidden: true) }, **notes
  has_many :listed_notes, -> { where(position: [1, 3]) }, **notes
  has_many :listed_or_unplaced_notes, -> { where(position: [1, nil]) }, **notes
  has_many :unlisted_notes, -> { where.not(position: [1, 3]) }, **notes
  has_many :placed_unlisted_notes, -> { where.not(position: [1, nil]) }, **notes
  has_many :hidden_or_first_notes, -> { where(hidden: true).or(where(position: 1)) }, **notes
  has_many :live_notes, -> { where(status: :live) }, **notes
  has_many :not_live_notes, -> { where.not(status: :live) }, **notes
  has_many :kept_notes, -> { where(deleted_at: nil) }, **notes
  has_many :trashed_notes, -> { where.not(deleted_at: nil) }, **notes
  has_many :top_notes, -> { order(:position, :id).limit(2) }, **notes
  has_many :later_notes, -> { order(:id).offset(1) }, **notes
  has_many :visible_page, -> { where(hidden: false).order(:position, :id).offset(1).limit(2) },
           **notes
  has_many :hidden_or_unknown_notes, -> { where(hidden: [true, nil]) }, **notes
  has_many :hidden_first_notes, -> { order(:hidden, :id).limit(2) }, **notes
  has_many :status_ranked_notes, -> { order(status: :desc, id: :asc).limit(2) }, **notes
  has_many :last_page_notes, -> { order(position: :desc, id: :desc).offset(1).limit(2) }, **notes
  has_many :not_live_and_hidden_notes, -> { where.not(status: :live, hidden: true) }, **notes
  has_one :latest_note, -> { order(id: :desc) }, **notes
  has_one :lowest_kept_note, -> { where(deleted_at: nil).order(:position, :id) }, **notes
  has_paper_trail synchronize_version_creation_timestamp: false
end

# Random edits that move notes into and out of each scope. Each takes a random
# note, which may be nil, and the post with the other post.
module OracleNoteEdits
  OPERATIONS = %i[create create edit edit trash restore move destroy root].freeze

  module_function

  def create(_note, random, posts)
    OracleNote.create!(post_id: posts.sample(random: random).id, **values(random).to_h)
  end

  def edit(note, random, _posts) = note&.update!(values(random).sample(2, random: random).to_h)
  def trash(note, _random, _posts) = note&.update!(deleted_at: Time.now.utc)
  def restore(note, _random, _posts) = note&.update!(deleted_at: nil)
  def destroy(note, _random, _posts) = note&.destroy!
  def root(_note, random, posts) = posts.first.update!(title: "post #{random.rand(1000)}")

  def move(note, _random, posts)
    note&.update!(post_id: posts.map(&:id).find { |id| id != note.post_id })
  end

  def values(random)
    [[:position, [nil, 1, 2, 3, 4].sample(random: random)],
     [:hidden, [nil, true, false].sample(random: random)],
     [:status, %w[draft live gone].sample(random: random)],
     [:body, [nil, 'a', 'b'].sample(random: random)]]
  end
end

RSpec.describe 'Rebuilt scoped membership against the recorded states' do
  let(:paths) do
    OraclePost.reflect_on_all_associations.map { |reflection| reflection.name.to_s }
              .grep_v('versions').sort
  end

  before do
    [PaperTrail::VersionAssociation, PaperTrail::Version, OracleNote, OraclePost]
      .each(&:delete_all)
  end

  def members(post)
    post = OraclePost.find(post.id)
    paths.to_h { |name| [name, Array(post.public_send(name)).map(&:id).sort] }
  end

  def snapshot_members(snapshot)
    paths.to_h do |name|
      [name, snapshot.associations.fetch(name).records.map(&:id).sort]
    end
  end

  def history(seed, steps)
    random = Random.new(seed)
    other = OraclePost.create!(title: 'other')
    post = nil
    recorder = Oracle::Recorder.new { [members(post), nil] }
    recorder.run(:create_post) { post = OraclePost.create!(title: 'post') }
    steps.times { recorder.run(:edit) { edit(random, post, other) } }
    [post.reload, recorder]
  end

  def edit(random, post, other)
    note = OracleNote.order(:id).to_a.sample(random: random)
    operation = OracleNoteEdits::OPERATIONS.sample(random: random)
    OracleNoteEdits.public_send(operation, note, random, [post, other])
  end

  Oracle.seeds([1, 2, 3]).each do |seed|
    it "rebuilds each scope's members at every root version (seed #{seed})" do
      post, recorder = history(seed, Oracle.steps(20))
      failures = Oracle::Failures.new(seed, recorder)
      versions = post.versions.reorder(:created_at, :id).to_a

      versions.each do |from|
        analysis = PaperTrailDiff.analyze(post, from: from, to: post, associations: paths)
        expected = recorder.before(from.id).state
        if expected
          failures.check("from #{from.id}", expected, snapshot_members(analysis.from_snapshot))
        end
        failures.check("to current from #{from.id}", recorder.final.state,
                       snapshot_members(analysis.to_snapshot))
      end
      PaperTrailDiff.activity_timeline(post, associations: paths, snapshots: true).each do |step|
        next unless step.to_snapshot

        failures.check("activity step to #{step.to_boundary.version_id.inspect}",
                       recorder.at(step.to_boundary).state, snapshot_members(step.to_snapshot))
      end

      expect(failures).to be_empty, -> { failures.message }
    end
  end
end
