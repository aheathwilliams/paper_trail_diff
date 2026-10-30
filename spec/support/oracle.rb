# frozen_string_literal: true

require_relative 'association_database'

# Checks rebuilt history against the truth rather than against another gem
# method. A generated history applies random edits one transaction at a time
# and records the live state after each, so every version names the state
# just before its transaction. Each reconstruction is then compared with the
# states it claims to show. A bug two methods share passes a consistency check;
# it fails here.
#
# The recorded state is read through the gem's current-record path, which is
# plain Active Record, and cross-checked against an independent read of each
# association's membership.
#
# Seeds and steps are fixed so a failure reproduces. `ORACLE_SEEDS=1..200` and
# `ORACLE_STEPS=40` widen a run.
module Oracle
  # Rebuilt collections do not yet follow the documented order.
  ORDERED = false

  # Collections are compared in the order the gem returns them. The reference
  # promises record type, then ID.
  def self.canon(value)
    case value
    when Hash then canon_hash(value)
    when Array then value.map { |item| canon(item) }
    when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
    else value
    end
  end

  def self.canon_hash(value)
    hash = value.to_h { |key, item| [key, canon(item)] }.sort_by { |key, _| key.to_s }.to_h
    records = hash[:records]
    return hash if ORDERED || !records.is_a?(Array)

    hash.merge(records: records.sort_by { |record| [record[:type], record[:id]] })
  end

  def self.snapshot(snapshot)
    snapshot && canon(snapshot.to_h)
  end

  def self.seeds(default)
    value = ENV.fetch('ORACLE_SEEDS', nil)
    return default unless value

    first, last = value.split('..').map { |part| Integer(part) }
    (first..(last || first)).to_a
  end

  def self.steps(default)
    Integer(ENV.fetch('ORACLE_STEPS', default))
  end

  def self.reset!
    [PaperTrail::VersionAssociation, PaperTrail::Version, TrackedReply, TrackedComment,
     TrackedProfile, TrackedAuthorship, TrackedArticle, TrackedAuthor, TrackedTag]
      .each(&:delete_all)
    ActiveRecord::Base.connection.execute('DELETE FROM tracked_articles_tags')
  end

  # The live state after each transaction, by the versions it wrote.
  class Recorder
    Entry = Struct.new(:name, :version_ids, :state, :membership, :after, keyword_init: true)

    attr_reader :entries

    # `observe` returns [state, membership] for the record as it is now.
    def initialize(&observe)
      @observe = observe
      @entries = [Entry.new(name: :none, version_ids: [])]
    end

    def run(name, &block)
      before = PaperTrail::Version.maximum(:id) || 0
      ActiveRecord::Base.transaction(&block)
      ids = PaperTrail::Version.where('id > ?', before).order(:id).pluck(:id)
      state, membership = @observe.call
      @entries << Entry.new(name: name, version_ids: ids, state: state, membership: membership,
                            after: Time.now.utc)
    end

    # The state before the transaction that wrote the version.
    def before(version_id)
      index = @entries.index { |entry| entry.version_ids.include?(version_id) }
      raise "no recorded transaction wrote version #{version_id}" unless index&.positive?

      @entries.fetch(index - 1)
    end

    # The state a step boundary stands for: before a version's transaction,
    # or now.
    def at(boundary)
      boundary.version? ? before(boundary.version_id) : final
    end

    def final
      @entries.last
    end

    # Versions written together with others. Their own steps cannot be told
    # apart from the transaction's in the recorded states.
    def shared_version_ids
      @entries.select { |entry| entry.version_ids.length > 1 }.flat_map(&:version_ids)
    end

    def describe
      @entries.map { |entry| [entry.name, entry.version_ids] }.inspect
    end
  end

  # Collects mismatches so one example reports every disagreement at once.
  class Failures
    def initialize(seed, recorder)
      @seed = seed
      @recorder = recorder
      @list = []
    end

    def check(label, expected, actual)
      @list << [label, expected, actual] unless expected == actual
    end

    def add(label, detail)
      @list << [label, detail, nil]
    end

    def empty?
      @list.empty?
    end

    def message
      lines = ["seed #{@seed}: #{@list.length} mismatches", "transactions: #{@recorder.describe}"]
      @list.first(5).each do |label, expected, actual|
        lines << label
        lines << "  expected: #{expected.inspect[0, 1500]}"
        lines << "  actual:   #{actual.inspect[0, 1500]}"
      end
      lines.join("\n")
    end
  end

  # Each association's members and a few of their values, read with plain
  # Active Record from the live rows or from a snapshot hash, to compare one
  # with the other.
  module Membership
    module_function

    def live(root)
      {
        'comments' => root.comments.order(:id).map do |comment|
          replies = comment.replies.order(:id).map { |reply| [reply.id, reply.body] }
          [comment.id, comment.body, replies]
        end,
        'author' => root.author&.then { |author| [author.id, author.name] },
        'profile' => root.profile&.then { |profile| [profile.id, profile.bio] },
        'authorships' => root.authorships.order(:id).map do |ship|
          [ship.id, ship.role, ship.author_id]
        end,
        'contributors' => root.contributors.distinct.order(:id).map do |author|
          [author.id, author.name]
        end
      }
    end

    def snapshot(state)
      associations = state.fetch(:associations, {})
      {
        'comments' => records(associations, 'comments').map { |comment| comment_row(comment) },
        'author' => one(associations, 'author', 'name'),
        'profile' => one(associations, 'profile', 'bio'),
        'authorships' => records(associations, 'authorships').map do |ship|
          [ship[:id], value(ship, 'role'), value(ship, 'author_id')]
        end,
        'contributors' => records(associations, 'contributors').map do |author|
          [author[:id], value(author, 'name')]
        end
      }
    end

    def comment_row(comment)
      replies = records(comment.fetch(:associations, {}), 'replies')
      replies = replies.map { |reply| [reply[:id], value(reply, 'body')] }
      [comment[:id], value(comment, 'body'), replies]
    end

    def records(associations, name)
      associations.fetch(name, {}).fetch(:records, []).sort_by { |record| record[:id] }
    end

    def one(associations, name, attribute)
      record = records(associations, name).first
      record && [record[:id], value(record, attribute)]
    end

    def value(record, attribute)
      record.fetch(:attributes).fetch(attribute)
    end
  end

  # A random article graph: comments with replies, an author, a profile, and
  # authorships with their authors. Some transactions write several versions.
  class ArticleHistory
    PATHS = ['comments.replies', 'author', 'profile', 'authorships', 'contributors'].freeze
    OPERATIONS = %i[
      edit_root checkpoint set_author edit_author
      create_comment edit_comment destroy_comment move_comment
      create_reply edit_reply destroy_reply move_reply
      create_profile edit_profile destroy_profile
      create_authorship edit_authorship destroy_authorship reassign_authorship
      edit_other combo touch
    ].freeze

    attr_reader :root, :recorder

    def initialize(seed, steps:)
      @random = Random.new(seed)
      @steps = steps
      @counter = 0
      @recorder = Recorder.new { observe }
    end

    def build
      @authors = Array.new(3) { |index| TrackedAuthor.create!(name: "author #{index}") }
      @other = TrackedArticle.create!(title: 'other 0')
      @recorder.run(:create_root) do
        @root = TrackedArticle.create!(title: 'root 0', author: @authors.first)
      end
      4.times { run(%i[create_comment create_reply].sample(random: @random)) }
      @steps.times { run(OPERATIONS.sample(random: @random)) }
      @root.reload
      self
    end

    # Ends the history with a root version, so every window has one after it.
    def close_with_root_edit
      run(:edit_root)
      @root.reload
      self
    end

    private

    def run(operation)
      @recorder.run(operation) { send(operation) }
    end

    def observe
      root = TrackedArticle.find(@root.id)
      analysis = PaperTrailDiff.analyze(root, from: root.versions.first, to: root,
                                              associations: PATHS)
      [Oracle.snapshot(analysis.to_snapshot), Membership.live(root)]
    end

    def next_number
      @counter += 1
    end

    def articles = [@root, @other]
    def comments = TrackedComment.where(article_id: articles.map(&:id)).order(:id).to_a
    def replies = TrackedReply.order(:id).to_a
    def profiles = TrackedProfile.order(:id).to_a
    def authorships = TrackedAuthorship.order(:id).to_a
    def any(list) = list.sample(random: @random)

    def edit_root = @root.update!(title: "root #{next_number}")
    def edit_other = @other.update!(title: "other #{next_number}")
    def checkpoint = TrackedArticle.find(@root.id).paper_trail.save_with_version
    def set_author = @root.update!(author: any([nil, *@authors]))
    def edit_author = any(@authors).update!(name: "author #{next_number}")
    def create_comment = any(articles).comments.create!(body: "comment #{next_number}")
    def edit_comment = any(comments)&.update!(body: "comment #{next_number}")

    def destroy_comment
      any(comments.select { |comment| comment.replies.empty? })&.destroy!
    end

    def move_comment
      comment = any(comments)
      comment&.update!(article_id: articles.find { |article| article.id != comment.article_id }.id)
    end

    def create_reply = any(comments)&.replies&.create!(body: "reply #{next_number}")
    def edit_reply = any(replies)&.update!(body: "reply #{next_number}")
    def destroy_reply = any(replies)&.destroy!

    def move_reply
      reply = any(replies)
      target = any(comments.reject { |comment| comment.id == reply&.comment_id })
      reply.update!(comment_id: target.id) if reply && target
    end

    def create_profile
      article = articles.find { |candidate| TrackedProfile.where(article_id: candidate.id).none? }
      article && TrackedProfile.create!(article_id: article.id, bio: "bio #{next_number}")
    end

    def edit_profile = any(profiles)&.update!(bio: "bio #{next_number}")
    def destroy_profile = any(profiles)&.destroy!

    def create_authorship
      TrackedAuthorship.create!(article_id: any(articles).id, author_id: any(@authors).id,
                                role: "role #{next_number}")
    end

    def edit_authorship = any(authorships)&.update!(role: "role #{next_number}")
    def destroy_authorship = any(authorships)&.destroy!
    def reassign_authorship = any(authorships)&.update!(author_id: any(@authors).id)

    # Several versions in one transaction.
    def combo
      edit_root
      create_comment
      edit_comment
    end

    # A child version saved before the root's, as `touch: true` saves them.
    def touch
      edit_comment
      edit_root
    end
  end

  # Compares every reconstruction of one history with its recorded states.
  class Checker
    def initialize(history, failures, paths: ArticleHistory::PATHS)
      @recorder = history.recorder
      @root = history.root
      @failures = failures
      @paths = paths
    end

    # The recorded states themselves, against plain Active Record.
    def membership
      @recorder.entries.each_with_index do |entry, index|
        next unless entry.state

        @failures.check("membership after transaction #{index}", entry.membership,
                        Membership.snapshot(entry.state))
      end
    end

    # Every pair of root versions, and each version to the current record.
    def endpoints
      versions = root_versions
      versions.each_with_index do |from, index|
        [*versions[(index + 1)..], @root].each { |to| endpoint(from, to) }
      end
    end

    # Each step of the activity timeline from each root version.
    def activity(group: nil)
      root_versions.each do |from|
        steps = PaperTrailDiff.activity_timeline(@root, from: from, to: @root, associations: @paths,
                                                        snapshots: true, group: group)
        steps.each_with_index do |step, index|
          source = step.source_boundary
          label = "activity from #{from.id} (group: #{group.inspect}) step #{index} " \
                  "(#{source.item_type} #{source.version_id})"
          step_states(label, step, grouped: !group.nil?)
        end
      end
    end

    # Windows between two recorded transactions, through every method that
    # takes one. Each window ends after a transaction, so it shows the state
    # recorded there.
    def windows(random, count: 8)
      entries = @recorder.entries
      count.times do
        first, last = (1...entries.length).to_a.sample(2, random: random).sort
        window(entries.fetch(first), entries.fetch(last), "window #{first}..#{last}")
      end
    end

    private

    def root_versions
      @root.versions.reorder(:created_at, :id).to_a
    end

    def endpoint(from, to)
      current = to.is_a?(TrackedArticle)
      label = "analyze #{from.id}->#{current ? 'current' : to.id}"
      analysis = PaperTrailDiff.analyze(@root, from: from, to: to, associations: @paths)
      expected_to = current ? @recorder.final : @recorder.before(to.id)
      @failures.check("#{label} from", @recorder.before(from.id).state,
                      Oracle.snapshot(analysis.from_snapshot))
      @failures.check("#{label} to", expected_to.state, Oracle.snapshot(analysis.to_snapshot))
      compared = PaperTrailDiff.compare(from, to, associations: @paths)
      @failures.check("#{label} compare", analysis.diff.to_h, compared.to_h)
    end

    def step_states(label, step, grouped:)
      return if !grouped && shared?(step)

      @failures.check("#{label} from", @recorder.before(step.source_boundary.version_id).state,
                      Oracle.snapshot(step.from_snapshot))
      @failures.check("#{label} to", @recorder.at(step.to_boundary).state,
                      Oracle.snapshot(step.to_snapshot))
      recomputed = PaperTrailDiff::Engine.compare(step.from_snapshot, step.to_snapshot)
      @failures.check("#{label} diff", recomputed.to_h, step.diff.to_h)
    end

    def shared?(step)
      shared = @recorder.shared_version_ids
      target = step.to_boundary
      shared.include?(step.source_boundary.version_id) ||
        (target.version? && shared.include?(target.version_id))
    end

    def window(first, last, label)
      within = first.after..last.after
      analysis = PaperTrailDiff.analyze(@root, within: within, associations: @paths, activity: true,
                                               snapshots: true)
      if analysis.activity_timeline.empty?
        @failures.check("#{label} is empty although the state changed", first.state, last.state)
        return
      end

      @failures.check("#{label} from", first.state, Oracle.snapshot(analysis.from_snapshot))
      @failures.check("#{label} to", last.state, Oracle.snapshot(analysis.to_snapshot))
      @failures.check("#{label} last step to", last.state,
                      Oracle.snapshot(analysis.activity_timeline.last.to_snapshot))
      batches(within, analysis, label)
    end

    def batches(within, analysis, label)
      key = PaperTrailDiff::Endpoint.identity(@root)
      many = PaperTrailDiff.analyze_many([@root], within: within, associations: @paths,
                                                  activity: true)
      @failures.check("#{label} analyze_many", analysis.diff.to_h, many.fetch(key).diff.to_h)
      return if analysis.diff.empty?

      relation = TrackedArticle.where(id: @root.id)
      scoped = PaperTrailDiff.analyze_scope(relation, within: within, associations: @paths,
                                                      activity: true, limit: 10)
      selected = scoped.analyses[key]
      unless selected
        return @failures.add("#{label} analyze_scope left out a changed root", analysis.diff.to_h)
      end

      @failures.check("#{label} analyze_scope", analysis.diff.to_h, selected.diff.to_h)
    end
  end
end
