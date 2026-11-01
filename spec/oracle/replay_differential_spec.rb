# frozen_string_literal: true

require_relative '../support/oracle'

# Activity carries each snapshot forward from the previous event, reading again
# only what the event changed. A full snapshot at every event is the reference
# it must agree with, so this replays generated histories both ways and fails
# on any difference. It needs no expected states, so unlike the other oracles
# it can use configurations whose truth is hard to state: `has_paper_trail
# only:` and `ignore:` that leave keys out of `object_changes`, and keys written
# by `update_columns` or with versioning off.
module ReplayDifferential
  GROUPS = [nil, :transaction].freeze
  PATHS = ['comments.replies', 'comments.reviewer', 'author', 'profile', 'authorships',
           'contributors'].freeze

  # The root's options, then the comments'.
  CONFIGURATIONS = {
    'Default' => [{}, {}],
    'Only' => [{ only: [:title] }, { only: [:body] }],
    'Ignore' => [{ ignore: [:author_id] }, { ignore: %i[reviewer_id article_id] }]
  }.freeze

  # Rebuilds every event's snapshot in full while `full` runs.
  module FullReplay
    def transition_snapshot(previous_event, event, previous_snapshot)
      return super unless Thread.current[:replay_differential_full]

      full_snapshot(event)
    end
  end
  PaperTrailDiff::ActivitySnapshotSequence.prepend(FullReplay)

  def self.full
    Thread.current[:replay_differential_full] = true
    yield
  ensure
    Thread.current[:replay_differential_full] = false
  end

  # Named classes on the tracked_* tables, one set per configuration. Named so
  # they are not collected while PaperTrail still refers to them.
  def self.models(configuration)
    @models ||= {}
    @models[configuration] ||= define_models(configuration)
  end

  def self.define_models(configuration) # rubocop:disable Metrics/MethodLength
    root_options, comment_options = CONFIGURATIONS.fetch(configuration)
    name = ->(model) { "Replay#{configuration}#{model}" }
    define = lambda do |model, table, &body|
      Object.const_set(name.call(model), Class.new(ActiveRecord::Base)).tap do |klass|
        klass.table_name = table
        klass.class_eval(&body)
      end
    end
    define.call('Author', 'tracked_authors') do
      has_paper_trail synchronize_version_creation_timestamp: false
    end
    define.call('Article', 'tracked_articles') do
      belongs_to :author, class_name: name.call('Author'), optional: true
      has_one :profile, class_name: name.call('Profile'), foreign_key: :article_id
      has_many :comments, class_name: name.call('Comment'), foreign_key: :article_id
      has_many :authorships, class_name: name.call('Authorship'), foreign_key: :article_id
      has_many :contributors, through: :authorships, source: :author
      has_paper_trail(**root_options, synchronize_version_creation_timestamp: false)
    end
    define.call('Comment', 'tracked_comments') do
      belongs_to :article, class_name: name.call('Article')
      belongs_to :reviewer, class_name: name.call('Author'), optional: true
      has_many :replies, class_name: name.call('Reply'), foreign_key: :comment_id
      has_paper_trail(**comment_options)
    end
    define.call('Reply', 'tracked_replies') do
      belongs_to :comment, class_name: name.call('Comment')
      has_paper_trail
    end
    define.call('Profile', 'tracked_profiles') do
      belongs_to :article, class_name: name.call('Article')
      has_paper_trail
    end
    define.call('Authorship', 'tracked_authorships') do
      belongs_to :article, class_name: name.call('Article')
      belongs_to :author, class_name: name.call('Author')
      has_paper_trail
    end
    %w[Author Article Comment Reply Profile Authorship].to_h do |model|
      [model, Object.const_get(name.call(model))]
    end
  end

  # What a step shows, with its snapshots.
  def self.steps(steps)
    steps.map do |step|
      [step.source_boundary.version_id, step.to_boundary.kind, step.to_boundary.version_id,
       step.sources.map(&:version_id), step.diff.to_h,
       step.from_snapshot&.to_h, step.to_snapshot&.to_h]
    end
  end

  # Random edits to two articles, some written without a version.
  class History
    OPERATIONS = %i[
      edit_root set_author edit_root_and_author silent_title silent_author unversioned_author
      checkpoint edit_other
      create_comment edit_comment destroy_comment move_comment silent_move_comment
      silent_edit_comment set_reviewer silent_reviewer edit_comment_and_move
      create_reply edit_reply destroy_reply move_reply
      create_profile edit_profile destroy_profile
      create_authorship edit_authorship destroy_authorship reassign_authorship
      edit_author combo
    ].freeze

    attr_reader :log

    def initialize(models, seed, steps:)
      @models = models
      @random = Random.new(seed)
      @steps = steps
      @counter = 0
      @log = []
    end

    def build
      @authors = Array.new(3) { |index| model('Author').create!(name: "author #{index}") }
      @root_id = model('Article').create!(title: 'root 0', author: @authors.first).id
      @other_id = model('Article').create!(title: 'other 0').id
      3.times { run(:create_comment) }
      @steps.times { run(OPERATIONS.sample(random: @random)) }
      self
    end

    def roots = [root, model('Article').find(@other_id)]

    private

    def run(operation)
      @log << operation
      ActiveRecord::Base.transaction { send(operation) }
    end

    def model(name) = @models.fetch(name)
    def text(prefix) = "#{prefix} #{@counter += 1}"
    def any(list) = list.sample(random: @random)
    def any_author = any([nil, *@authors])
    def root = model('Article').find(@root_id)
    def articles = [root, model('Article').find(@other_id)]
    def comments = model('Comment').order(:id).to_a
    def replies = model('Reply').order(:id).to_a
    def profiles = model('Profile').order(:id).to_a
    def authorships = model('Authorship').order(:id).to_a
    def elsewhere(comment) = [@root_id, @other_id].find { |id| id != comment.article_id }

    def edit_root = root.update!(title: text('root'))
    def edit_other = model('Article').find(@other_id).update!(title: text('other'))
    def set_author = root.update!(author: any_author)
    def edit_root_and_author = root.update!(title: text('root'), author: any_author)
    def silent_title = root.update_columns(title: text('root'))
    def silent_author = root.update_columns(author_id: any_author&.id)
    def unversioned_author = PaperTrail.request(enabled: false) { set_author }
    def checkpoint = root.paper_trail.save_with_version
    def create_comment = any(articles).comments.create!(body: text('comment'))
    def edit_comment = any(comments)&.update!(body: text('comment'))
    def destroy_comment = any(comments.select { |comment| comment.replies.empty? })&.destroy!
    def silent_edit_comment = any(comments)&.update_columns(body: text('comment'))
    def set_reviewer = any(comments)&.update!(reviewer: any_author)
    def silent_reviewer = any(comments)&.update_columns(reviewer_id: any_author&.id)
    def create_reply = any(comments)&.replies&.create!(body: text('reply'))
    def edit_reply = any(replies)&.update!(body: text('reply'))
    def destroy_reply = any(replies)&.destroy!
    def edit_profile = any(profiles)&.update!(bio: text('bio'))
    def destroy_profile = any(profiles)&.destroy!
    def edit_authorship = any(authorships)&.update!(role: text('role'))
    def destroy_authorship = any(authorships)&.destroy!
    def reassign_authorship = any(authorships)&.update!(author_id: any(@authors).id)
    def edit_author = any(@authors).reload.update!(name: text('author'))

    def move_comment
      comment = any(comments)
      comment&.update!(article_id: elsewhere(comment))
    end

    def silent_move_comment
      comment = any(comments)
      comment&.update_columns(article_id: elsewhere(comment))
    end

    def edit_comment_and_move
      comment = any(comments)
      comment&.update!(body: text('comment'), article_id: elsewhere(comment))
    end

    def move_reply
      reply = any(replies) or return
      target = any(comments.reject { |comment| comment.id == reply.comment_id })
      reply.update!(comment_id: target.id) if target
    end

    def create_profile
      article = articles.find { |candidate| model('Profile').where(article_id: candidate.id).none? }
      article && model('Profile').create!(article_id: article.id, bio: text('bio'))
    end

    def create_authorship
      model('Authorship').create!(article_id: any(articles).id, author_id: any(@authors).id,
                                  role: text('role'))
    end

    def combo
      edit_root
      create_comment
      edit_comment
    end
  end
end

RSpec.describe 'Activity replay against a full snapshot at every event' do
  before { Oracle.reset! }

  def activity(root, from)
    lambda do |group|
      ReplayDifferential.steps(PaperTrailDiff.activity_timeline(
                                 root, from: from, to: root, associations: ReplayDifferential::PATHS,
                                       snapshots: true, group: group
                               ))
    end
  end

  def window(root, first, last)
    lambda do
      analysis = PaperTrailDiff.analyze(root, within: first.created_at..last.created_at,
                                              associations: ReplayDifferential::PATHS,
                                              activity: true, snapshots: true)
      [analysis.diff.to_h, ReplayDifferential.steps(analysis.activity_timeline)]
    end
  end

  # Each read, from several starts and over random windows, both ways.
  def mismatches(history, seed)
    random = Random.new(seed)
    versions = PaperTrail::Version.order(:created_at, :id).to_a
    history.roots.flat_map do |root|
      reads = root.versions.reorder(:created_at, :id).first(4).flat_map do |from|
        ReplayDifferential::GROUPS.map do |group|
          ["#{root.id} from #{from.id} group #{group.inspect}",
           -> { activity(root, from).call(group) }]
        end
      end
      reads += Array.new(3) do
        first, last = versions.sample(2, random: random).sort_by(&:id)
        ["#{root.id} within #{first.id}..#{last.id}", window(root, first, last)]
      end
      reads.filter_map { |label, read| label unless read.call == ReplayDifferential.full(&read) }
    end
  end

  ReplayDifferential::CONFIGURATIONS.each_key do |configuration|
    Oracle.seeds([1, 2]).each do |seed|
      it "agrees under the #{configuration.downcase} configuration for seed #{seed}" do
        models = ReplayDifferential.models(configuration)
        history = ReplayDifferential::History.new(models, seed, steps: Oracle.steps(24)).build

        expect(mismatches(history, seed)).to be_empty, -> { "transactions: #{history.log.inspect}" }
      end
    end
  end
end
