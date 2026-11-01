# frozen_string_literal: true

require_relative '../support/oracle'

# The state each article should show, read with plain Active Record, and the
# state of every tag, member or not, so a step can name the tags a later
# checkpoint recorded as they were at the step.
module OracleHabtmTruth
  PATHS = [%w[tags], %w[tags comments], %w[tags author]].freeze

  module_function

  def states(root_ids)
    roots = root_ids.product(PATHS).to_h { |id, paths| [[id, paths], snapshot(id, paths)] }
    tags = TrackedTag.order(:id).to_h { |tag| [tag.id, record(tag)] }
    { roots: roots, tags: tags }
  end

  def snapshot(id, paths)
    article = TrackedArticle.find_by(id: id)
    return unless article

    excluded = paths.include?('author') ? %w[author_id] : []
    associations = paths.to_h { |name| [name, association(article, name)] }
    record(article, except: excluded, associations: associations)
  end

  def association(article, name)
    reflection = TrackedArticle.reflect_on_association(name)
    members = Array(TrackedArticle.find(article.id).public_send(name))
    incoming = reflection.macro == :has_many ? [reflection.foreign_key.to_s] : []
    records = members.map { |member| record(member, except: incoming) }
    PaperTrailDiff::AssociationSnapshot.new(kind: reflection.macro, records: records)
  end

  def record(model, except: [], associations: {})
    attributes = model.attributes.except(model.class.primary_key, 'updated_at', *except)
    PaperTrailDiff::RecordSnapshot.new(type: model.class.name, id: model.id,
                                       attributes: attributes, associations: associations)
  end
end

# Random tag edits on two articles, each saved through a fresh `find` as the
# reference asks. A transaction that saves a root version changes tags only
# before the save, so the version records the tags the transaction ends with.
class OracleHabtmHistory
  OPERATIONS = %i[
    attach attach detach checkpoint edit_root attach_and_checkpoint
    detach_and_edit_root create_tag_attach_checkpoint create_tag create_tag_and_attach
    edit_tag destroy_tag create_comment edit_comment other_attach other_checkpoint
  ].freeze

  attr_reader :recorder, :root_id

  def initialize(seed, steps:)
    @random = Random.new(seed)
    @steps = steps
    @counter = 0
    @recorder = Oracle::Recorder.new { [nil, nil, OracleHabtmTruth.states([@root_id].compact)] }
  end

  def build
    @recorder.run(:setup) { setup }
    @steps.times do
      operation = OPERATIONS.sample(random: @random)
      @recorder.run(operation) { send(operation) }
    end
    @recorder.run(:closing_checkpoint) { checkpoint }
    self
  end

  # A last tag change after the last root version, for the current endpoint.
  def close_with_live_change
    @recorder.run(:attach) { attach }
    self
  end

  private

  def setup
    @author = TrackedAuthor.create!(name: 'author')
    @other_id = TrackedArticle.create!(title: 'other').id
    Array.new(3) { |index| TrackedTag.create!(name: "tag #{index}") }
    @root_id = TrackedArticle.create!(title: 'root 0', author: @author).id
  end

  def next_number = @counter += 1
  def any(list) = list.sample(random: @random)
  def root = TrackedArticle.find(@root_id)
  def tags = TrackedTag.order(:id).to_a

  def attach(article_id = @root_id)
    article = TrackedArticle.find(article_id)
    tag = any(tags - article.tags.to_a)
    article.tags << tag if tag
  end

  def detach
    article = root
    tag = any(article.tags.to_a)
    article.tags.delete(tag) if tag
  end

  def checkpoint = root.paper_trail.save_with_version
  def edit_root = root.update!(title: "root #{next_number}")

  def attach_and_checkpoint
    attach
    checkpoint
  end

  def detach_and_edit_root
    detach
    edit_root
  end

  def create_tag_attach_checkpoint
    root.tags << TrackedTag.create!(name: "tag #{next_number}")
    checkpoint
  end

  def create_tag = TrackedTag.create!(name: "tag #{next_number}")
  def create_tag_and_attach = root.tags << create_tag
  def edit_tag = any(tags)&.update!(name: "tag #{next_number}")
  def destroy_tag = any(tags)&.destroy!
  def create_comment = root.comments.create!(body: "comment #{next_number}")
  def edit_comment = any(root.comments.to_a)&.update!(body: "comment #{next_number}")
  def other_attach = attach(@other_id)
  def other_checkpoint = TrackedArticle.find(@other_id).paper_trail.save_with_version
end

RSpec.describe 'Rebuilt HABTM history against the recorded states' do
  before { Oracle.reset! }

  def entries(history) = history.recorder.entries

  def entry_index(history, version_id)
    entries(history).index { |entry| entry.version_ids.include?(version_id) }
  end

  def root_versions(history)
    TrackedArticle.find(history.root_id).versions.reorder(:created_at, :id).to_a
  end

  # The tags the gem can know at the point just before transaction `index`,
  # or just before version `boundary` inside it: the members the next root
  # version recorded, as each tag was at that point. A tag created in that
  # version's own transaction is read as it was created, from its creation
  # on.
  def state_at(history, index, paths, boundary: nil)
    key = [history.root_id, paths]
    base = entries(history).fetch(index - 1).snapshot&.fetch(:roots)&.fetch(key, nil)
    return unless base

    version = root_versions(history).find do |candidate|
      entry_index(history, candidate.id) >= index
    end
    return base unless version

    recorded_at = entry_index(history, version.id)
    with_tags(base, recorded_tags(history, index, recorded_at, key, boundary))
  end

  def recorded_tags(history, index, recorded_at, key, boundary)
    before = entries(history).fetch(index - 1).snapshot&.fetch(:tags) || {}
    after = entries(history).fetch(recorded_at).snapshot
    after.fetch(:roots).fetch(key).associations.fetch('tags').records.filter_map do |tag|
      before[tag.id] || (after.fetch(:tags)[tag.id] if created_before?(tag, boundary, index,
                                                                       recorded_at))
    end
  end

  def created_before?(tag, boundary, index, recorded_at)
    return false unless boundary && index == recorded_at

    created = PaperTrail::Version.where(item_type: 'TrackedTag', item_id: tag.id, event: 'create')
    created.pick(:id).to_i < boundary
  end

  def with_tags(snapshot, records)
    tags = PaperTrailDiff::AssociationSnapshot.new(kind: :has_and_belongs_to_many, records: records)
    PaperTrailDiff::RecordSnapshot.new(type: snapshot.type, id: snapshot.id,
                                       attributes: snapshot.attributes,
                                       associations: snapshot.associations.merge('tags' => tags))
  end

  def at_boundary(history, boundary, paths)
    state_at(history, entry_index(history, boundary.version_id), paths,
             boundary: boundary.version_id)
  end

  def live(history, paths)
    entries(history).last.snapshot.fetch(:roots).fetch([history.root_id, paths])
  end

  def at_version(history, version, paths)
    state_at(history, entry_index(history, version.id), paths, boundary: version.id)
  end

  def mismatch(expected, actual)
    change = PaperTrailDiff::Engine.compare(expected, actual)
    change.empty? ? {} : change.to_h
  end

  def diff(before, after) = PaperTrailDiff::Engine.compare(before, after).to_h

  def check_endpoints(history, failures, paths)
    root = TrackedArticle.find(history.root_id)
    versions = root_versions(history)
    versions.each_with_index do |from, index|
      [*versions[(index + 1)..], root].each do |to|
        current = to.is_a?(TrackedArticle)
        expected_to = current ? live(history, paths) : at_version(history, to, paths)
        label = "compare #{paths.inspect} #{from.id}->#{current ? 'current' : to.id}"
        failures.check(label, diff(at_version(history, from, paths), expected_to),
                       PaperTrailDiff.compare(from, to, associations: paths).to_h)
      end
    end
  end

  def check_timeline(history, failures, paths)
    root = TrackedArticle.find(history.root_id)
    versions = root_versions(history)
    steps = PaperTrailDiff.timeline(root, from: versions.first, to: root, associations: paths)
    ends = [*versions.drop(1).map { |version| at_version(history, version, paths) },
            live(history, paths)]
    return failures.add("timeline #{paths.inspect} step count", [steps.length, ends.length]) if
      steps.length != ends.length

    steps.zip(versions, ends).each do |step, from, last|
      failures.check("timeline #{paths.inspect} from #{from.id}",
                     diff(at_version(history, from, paths), last), step.diff.to_h)
    end
  end

  # Activity from each root version to the next one and to the last, grouped
  # and not. A range ending at a checkpoint leaves out the rest of its
  # transaction.
  def check_activity(history, failures, paths)
    versions = root_versions(history)
    versions.each_with_index do |from, index|
      [versions[index + 1], versions.last].compact.uniq.drop_while { |to| to == from }.each do |to|
        Oracle::Checker::GROUPS.each do |group|
          check_activity_range(history, failures, paths, from, to, group)
        end
      end
    end
  end

  def check_activity_range(history, failures, paths, from, to, group) # rubocop:disable Metrics/ParameterLists
    root = TrackedArticle.find(history.root_id)
    range = "#{paths.inspect} #{from.id}->#{to.id} (group: #{group.inspect})"
    steps = PaperTrailDiff.activity_timeline(root, from: from, to: to, associations: paths,
                                                   group: group, snapshots: true)
    steps.each_with_index do |step, index|
      label = "activity #{range} step #{index} " \
              "(#{step.source_boundary.item_type} #{step.source_boundary.version_id})"
      from_state = at_boundary(history, step.source_boundary, paths)
      failures.check("#{label} from", {}, mismatch(from_state, step.from_snapshot))
      failures.check("#{label} to", {},
                     mismatch(at_boundary(history, step.to_boundary, paths), step.to_snapshot))
    end
    return if steps.empty?

    failures.check("activity #{range} ends at its last version", {},
                   mismatch(at_version(history, to, paths), steps.last.to_snapshot))
  end

  # Windows between two transactions, each with a root version after it.
  def check_windows(history, failures, paths, random)
    last_root = entry_index(history, root_versions(history).last.id)
    first_root = entry_index(history, root_versions(history).first.id)
    6.times do
      first, last = (first_root...last_root).to_a.sample(2, random: random).sort
      next unless last

      window(history, failures, paths, first, last)
    end
  end

  def window(history, failures, paths, first, last)
    within = entries(history).fetch(first).after..entries(history).fetch(last).after
    label = "window #{paths.inspect} after #{first}..after #{last}"
    root = TrackedArticle.find(history.root_id)
    analysis = PaperTrailDiff.analyze(root, within: within, associations: paths, activity: true,
                                            snapshots: true)
    expected = [state_at(history, first + 1, paths), state_at(history, last + 1, paths)]
    if analysis.activity_timeline.empty?
      return failures.check("#{label} is empty although the state changed", {}, mismatch(*expected))
    end

    failures.check("#{label} from", {}, mismatch(expected.first, analysis.from_snapshot))
    failures.check("#{label} to", {}, mismatch(expected.last, analysis.to_snapshot))
    many = PaperTrailDiff.analyze_many([root], within: within, associations: paths, activity: true)
    failures.check("#{label} analyze_many", analysis.diff.to_h, many.values.first.diff.to_h)
  end

  def check_live_activity_refused(history, failures, paths)
    root = TrackedArticle.find(history.root_id)
    PaperTrailDiff.activity_timeline(root, associations: paths)
    failures.add("activity #{paths.inspect} to the current record did not raise", nil)
  rescue PaperTrailDiff::UnsupportedLiveActivityError
    nil
  end

  Oracle.seeds([1, 3]).each do |seed|
    it "rebuilds every endpoint, timeline step, activity step and window (seed #{seed})" do
      history = OracleHabtmHistory.new(seed, steps: Oracle.steps(20)).build.close_with_live_change
      failures = Oracle::Failures.new(seed, history.recorder)
      OracleHabtmTruth::PATHS.each do |paths|
        check_endpoints(history, failures, paths)
        check_timeline(history, failures, paths)
        check_activity(history, failures, paths)
        check_windows(history, failures, paths, Random.new(seed))
        check_live_activity_refused(history, failures, paths)
      end

      expect(failures).to be_empty, -> { failures.message }
    end
  end
end
