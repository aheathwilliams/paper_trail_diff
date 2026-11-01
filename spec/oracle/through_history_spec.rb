# frozen_string_literal: true

require_relative '../support/oracle'

ActiveRecord::Schema.define do
  create_table :oracle_teams, force: true do |table|
    table.string :name
    table.timestamps
  end

  create_table :oracle_people, force: true do |table|
    table.string :name
    table.integer :rank
    table.timestamps
  end

  create_table :oracle_memberships, force: true do |table|
    table.integer :team_id
    table.integer :person_id
    table.boolean :lead, null: false, default: false
    table.timestamps
  end

  create_table :oracle_projects, force: true do |table|
    table.integer :team_id
    table.string :title
    table.timestamps
  end

  create_table :oracle_tasks, force: true do |table|
    table.integer :project_id
    table.string :title
    table.timestamps
  end

  create_table :oracle_task_notes, force: true do |table|
    table.integer :task_id
    table.string :body
    table.timestamps
  end

  create_table :oracle_charters, force: true do |table|
    table.integer :team_id
    table.integer :author_id
    table.string :text
    table.timestamps
  end

  create_table :oracle_assignments, force: true do |table|
    table.integer :team_id
    table.string :assignee_type
    table.integer :assignee_id
    table.timestamps
  end
end

# Every kind of `has_many :through` the gem rebuilds from history: through a
# has_many to a belongs_to, through a scoped part, ranked with a limit, to a
# has_many, through another through, a has_one through, and with
# `source_type:`.
class OracleTeam < ActiveRecord::Base
  has_many :memberships, class_name: 'OracleMembership', foreign_key: :team_id,
                         inverse_of: :team
  has_many :people, through: :memberships
  has_many :lead_memberships, -> { where(lead: true) }, class_name: 'OracleMembership',
                                                        foreign_key: :team_id,
                                                        inverse_of: :team
  has_many :leads, through: :lead_memberships, source: :person
  has_many :top_people, -> { order(:rank, :id).limit(2) }, through: :memberships,
                                                           source: :person
  has_many :projects, class_name: 'OracleProject', foreign_key: :team_id, inverse_of: :team
  has_many :tasks, through: :projects
  has_many :notes, through: :tasks
  has_one :charter, class_name: 'OracleCharter', foreign_key: :team_id, inverse_of: :team
  has_one :charter_author, through: :charter, source: :author
  has_many :assignments, class_name: 'OracleAssignment', foreign_key: :team_id,
                         inverse_of: :team
  has_many :assigned_people, through: :assignments, source: :assignee,
                             source_type: 'OraclePerson'
  has_paper_trail
end

class OraclePerson < ActiveRecord::Base
  has_many :memberships, class_name: 'OracleMembership', foreign_key: :person_id,
                         inverse_of: :person
  has_paper_trail
end

class OracleMembership < ActiveRecord::Base
  belongs_to :team, class_name: 'OracleTeam', optional: true, inverse_of: :memberships
  belongs_to :person, class_name: 'OraclePerson', optional: true, inverse_of: :memberships
  has_paper_trail
end

class OracleProject < ActiveRecord::Base
  belongs_to :team, class_name: 'OracleTeam', optional: true, inverse_of: :projects
  has_many :tasks, class_name: 'OracleTask', foreign_key: :project_id, inverse_of: :project
  has_paper_trail
end

class OracleTask < ActiveRecord::Base
  belongs_to :project, class_name: 'OracleProject', optional: true, inverse_of: :tasks
  has_many :notes, class_name: 'OracleTaskNote', foreign_key: :task_id, inverse_of: :task
  has_paper_trail
end

class OracleTaskNote < ActiveRecord::Base
  belongs_to :task, class_name: 'OracleTask', optional: true, inverse_of: :notes
  has_paper_trail
end

class OracleCharter < ActiveRecord::Base
  belongs_to :team, class_name: 'OracleTeam', optional: true, inverse_of: :charter
  belongs_to :author, class_name: 'OraclePerson', optional: true
  has_paper_trail
end

class OracleAssignment < ActiveRecord::Base
  belongs_to :team, class_name: 'OracleTeam', optional: true, inverse_of: :assignments
  belongs_to :assignee, polymorphic: true, optional: true
  has_paper_trail
end

# The state each team should show, read with plain Active Record. A record
# leaves out its primary key, `updated_at`, the key a has_one or has_many
# child points back with, and the keys of the belongs_to associations it is
# read through, as snapshots do. A through reaches a record once per join row
# that leads to it; it is one member.
module OracleThroughTruth
  PATHS = [%w[people leads top_people], %w[memberships.person tasks notes],
           %w[charter_author assigned_people projects.tasks.notes],
           %w[people.memberships tasks.notes charter.author]].freeze

  module_function

  def states(root_ids)
    root_ids.product(PATHS).to_h { |id, paths| [[id, paths], snapshot(id, tree(paths))] }
  end

  def snapshot(id, tree)
    record = OracleTeam.find_by(id: id)
    record && build(record, tree, [])
  end

  def build(record, tree, incoming)
    reflections = tree.keys.map { |name| record.class.reflect_on_association(name) }
    keys = reflections.select(&:belongs_to?).flat_map do |reflection|
      [reflection.foreign_key.to_s, *(reflection.foreign_type.to_s if reflection.polymorphic?)]
    end
    attributes = record.attributes.except(record.class.primary_key, 'updated_at', *incoming, *keys)
    associations = reflections.to_h do |reflection|
      [reflection.name.to_s, association(record, reflection, tree.fetch(reflection.name.to_s))]
    end
    PaperTrailDiff::RecordSnapshot.new(type: record.class.name, id: record.id,
                                       attributes: attributes, associations: associations)
  end

  def association(record, reflection, subtree)
    members = Array(record.class.find(record.id).public_send(reflection.name))
    members = members.uniq { |member| [member.class.name, member.id] }
    direct = !reflection.belongs_to? && !reflection.through_reflection?
    child_keys = direct ? [reflection.foreign_key.to_s, *reflection.type&.to_s] : []
    records = members.map { |member| build(member, subtree, child_keys) }
    PaperTrailDiff::AssociationSnapshot.new(kind: reflection.macro, records: records)
  end

  def tree(paths)
    paths.each_with_object({}) do |path, root|
      path.split('.').inject(root) { |branch, name| branch[name] ||= {} }
    end
  end
end

# Random edits to two teams, their join records, and the records the joins
# reach. Each operation takes the history's random source.
class OracleThroughHistory
  OPERATIONS = %i[
    edit_team add_person edit_person edit_person destroy_person
    join join leave change_lead move_membership swap_person
    add_project move_project destroy_project
    add_task add_task move_task edit_task destroy_task
    add_note move_note edit_note destroy_note
    add_charter edit_charter change_charter_author destroy_charter
    assign retarget_assignment unassign combo
  ].freeze

  attr_reader :recorder, :root_ids

  def initialize(seed, steps:)
    @random = Random.new(seed)
    @steps = steps
    @counter = 0
    @root_ids = []
    @recorder = Oracle::Recorder.new { [nil, nil, OracleThroughTruth.states(@root_ids)] }
  end

  def build
    @recorder.run(:teams) { plant }
    @steps.times do
      operation = OPERATIONS.sample(random: @random)
      @recorder.run(operation) { send(operation) }
    end
    self
  end

  private

  def plant
    people = Array.new(3) { |index| OraclePerson.create!(name: "person #{index}", rank: index) }
    teams = Array.new(2) do |index|
      team = OracleTeam.create!(name: "team #{index}")
      OracleMembership.create!(team: team, person: people[index], lead: true)
      project = OracleProject.create!(team: team, title: "project #{index}")
      task = OracleTask.create!(project: project, title: "task #{index}")
      OracleTaskNote.create!(task: task, body: "note #{index}")
      team
    end
    @root_ids = teams.map(&:id)
  end

  def next_number = @counter += 1
  def any(list) = list.sample(random: @random)
  def teams = OracleTeam.order(:id).to_a
  def people = OraclePerson.order(:id).to_a
  def memberships = OracleMembership.order(:id).to_a
  def projects = OracleProject.order(:id).to_a
  def tasks = OracleTask.order(:id).to_a
  def notes = OracleTaskNote.order(:id).to_a
  def charters = OracleCharter.order(:id).to_a
  def assignments = OracleAssignment.order(:id).to_a
  def lead = any([true, false])
  def rank = @random.rand(4)

  def edit_team = any(teams).update!(name: "team #{next_number}")
  def add_person = OraclePerson.create!(name: "person #{next_number}", rank: rank)
  def destroy_person = any(people)&.destroy!

  # A rank tie leaves the ID to order the ranked through.
  def edit_person
    person = any(people)
    return unless person

    changes = [{ name: "person #{next_number}" }, { rank: rank },
               { name: "person #{next_number}", rank: rank }]
    person.update!(any(changes))
  end

  def join
    person = any(people)
    person && OracleMembership.create!(team: any(teams), person: person, lead: lead)
  end

  def leave = any(memberships)&.destroy!

  def change_lead
    membership = any(memberships)
    membership&.update!(lead: !membership.lead)
  end

  def move_membership
    membership = any(memberships)
    membership&.update!(team_id: (teams.map(&:id) - [membership.team_id]).first)
  end

  def swap_person
    person = any(people)
    any(memberships)&.update!(person_id: person.id) if person
  end

  def add_project = OracleProject.create!(team: any(teams), title: "project #{next_number}")
  def move_project = any(projects)&.update!(team: any(teams))
  def destroy_project = any(projects.reject { |project| project.tasks.any? })&.destroy!

  def add_task
    project = any(projects)
    project && OracleTask.create!(project: project, title: "task #{next_number}")
  end

  def move_task
    project = any(projects)
    any(tasks)&.update!(project: project) if project
  end

  def edit_task = any(tasks)&.update!(title: "task #{next_number}")
  def destroy_task = any(tasks.reject { |task| task.notes.any? })&.destroy!

  def add_note
    task = any(tasks)
    task && OracleTaskNote.create!(task: task, body: "note #{next_number}")
  end

  def move_note
    task = any(tasks)
    any(notes)&.update!(task: task) if task
  end

  def edit_note = any(notes)&.update!(body: "note #{next_number}")
  def destroy_note = any(notes)&.destroy!

  def add_charter
    team = any(teams.reject(&:charter))
    team && OracleCharter.create!(team: team, author: any([nil, *people]),
                                  text: "charter #{next_number}")
  end

  def edit_charter = any(charters)&.update!(text: "charter #{next_number}")
  def change_charter_author = any(charters)&.update!(author: any([nil, *people]))
  def destroy_charter = any(charters)&.destroy!

  def assign
    assignee = any([*people, *tasks])
    assignee && OracleAssignment.create!(team: any(teams), assignee: assignee)
  end

  def retarget_assignment
    assignee = any([*people, *tasks])
    any(assignments)&.update!(assignee: assignee) if assignee
  end

  def unassign = any(assignments)&.destroy!

  # Several versions in one transaction, some of them undoing each other.
  def combo
    3.times { send(any(%i[join leave change_lead move_task edit_person swap_person edit_team])) }
  end
end

RSpec.describe 'Rebuilt has_many :through history against the recorded states' do
  before do
    [PaperTrail::VersionAssociation, PaperTrail::Version, OracleTeam, OraclePerson,
     OracleMembership, OracleProject, OracleTask, OracleTaskNote, OracleCharter,
     OracleAssignment].each(&:delete_all)
  end

  def state(entry, key)
    entry.snapshot&.fetch(key, nil)
  end

  def diff(before, after)
    PaperTrailDiff::Engine.compare(before, after).to_h
  end

  # What separates a rebuilt snapshot from the recorded one, or nothing.
  def mismatch(expected, actual)
    change = PaperTrailDiff::Engine.compare(expected, actual)
    change.empty? ? {} : change.to_h
  end

  # The change each transaction made that the team's paths can see.
  def expected_steps(recorder, key, from)
    first = recorder.entries.index { |entry| entry.version_ids.include?(from.id) }
    recorder.entries.each_cons(2).drop(first - 1).filter_map do |before, after|
      change = PaperTrailDiff::Engine.compare(state(before, key), state(after, key))
      change.to_h unless change.empty?
    end
  end

  def check_root(history, failures, root, paths)
    key = [root.id, paths]
    recorder = history.recorder
    versions = root.versions.reorder(:created_at, :id).to_a
    versions.each_with_index do |from, index|
      [versions[index + 1], root].compact.each do |to|
        check_compare(failures, recorder, key, from, to)
      end
    end
    check_timeline(failures, recorder, root, paths, versions)
    steps = PaperTrailDiff.activity_timeline(root, associations: paths, group: :transaction)
    failures.check("activity #{key.inspect}", expected_steps(recorder, key, versions.first),
                   steps.reject(&:empty?).map { |step| step.diff.to_h })
    check_activity_states(failures, recorder, root, paths, versions.first)
  end

  def check_compare(failures, recorder, key, from, to)
    current = to.is_a?(OracleTeam)
    expected_to = current ? recorder.final : recorder.before(to.id)
    failures.check("compare #{key.inspect} #{from.id}->#{current ? 'current' : to.id}",
                   diff(state(recorder.before(from.id), key), state(expected_to, key)),
                   PaperTrailDiff.compare(from, to, associations: key.last).to_h)
  end

  def check_timeline(failures, recorder, root, paths, versions)
    key = [root.id, paths]
    steps = PaperTrailDiff.timeline(root, from: versions.first, to: root, associations: paths)
    ends = [*versions.drop(1).map { |version| recorder.before(version.id) }, recorder.final]
    return failures.add("timeline #{key.inspect} step count", [steps.length, ends.length]) if
      steps.length != ends.length

    steps.zip(versions, ends).each do |step, from, last|
      failures.check("timeline #{key.inspect} from #{from.id}",
                     diff(state(recorder.before(from.id), key), state(last, key)), step.diff.to_h)
    end
  end

  # Each grouped step's snapshots are the states before and after its
  # transaction.
  def check_activity_states(failures, recorder, root, paths, from)
    key = [root.id, paths]
    steps = PaperTrailDiff.activity_timeline(root, from: from, to: root, associations: paths,
                                                   group: :transaction, snapshots: true)
    steps.each_with_index do |step, index|
      label = "activity #{key.inspect} step #{index} (#{step.source_boundary.version_id})"
      before = recorder.before(step.source_boundary.version_id)
      failures.check("#{label} from", {}, mismatch(state(before, key), step.from_snapshot))
      failures.check("#{label} to", {},
                     mismatch(state(recorder.at(step.to_boundary), key), step.to_snapshot))
    end
  end

  # Windows between two recorded transactions, over both teams at once.
  def check_windows(history, failures, random)
    roots = OracleTeam.where(id: history.root_ids).order(:id).to_a
    entries = history.recorder.entries
    4.times do
      first, last = (1...entries.length).to_a.sample(2, random: random).sort
      OracleThroughTruth::PATHS.each do |paths|
        check_window(failures, roots, paths, entries.fetch(first), entries.fetch(last))
      end
    end
  end

  def check_window(failures, roots, paths, first, last)
    within = first.after..last.after
    many = PaperTrailDiff.analyze_many(roots, within: within, associations: paths, activity: true)
    roots.each do |root|
      key = [root.id, paths]
      expected = diff(state(first, key), state(last, key))
      label = "#{key.inspect} within #{first.after.iso8601(6)}..#{last.after.iso8601(6)}"
      failures.check("analyze_many #{label}", expected,
                     many.fetch(PaperTrailDiff::Endpoint.identity(root)).diff.to_h)
      single = PaperTrailDiff.analyze(root, within: within, associations: paths, activity: true)
      failures.check("analyze #{label}", expected, single.diff.to_h)
    end
  end

  # The truth itself must agree with the gem on the live rows, which it reads
  # without history; otherwise every other check would compare conventions.
  def check_current(history, failures)
    OracleTeam.where(id: history.root_ids).order(:id).each do |root|
      OracleThroughTruth::PATHS.each do |paths|
        live = PaperTrailDiff.analyze(root, from: root.versions.first, to: root,
                                            associations: paths)
        failures.check("current #{[root.id, paths].inspect}", {},
                       mismatch(state(history.recorder.final, [root.id, paths]), live.to_snapshot))
      end
    end
  end

  Oracle.seeds([1, 4]).each do |seed|
    it "rebuilds every through, endpoint pair, timeline, activity step and window (seed #{seed})" do
      history = OracleThroughHistory.new(seed, steps: Oracle.steps(24)).build
      failures = Oracle::Failures.new(seed, history.recorder)
      check_current(history, failures)
      OracleTeam.where(id: history.root_ids).order(:id).each do |root|
        OracleThroughTruth::PATHS.each { |paths| check_root(history, failures, root, paths) }
      end
      check_windows(history, failures, Random.new(seed))

      expect(failures).to be_empty, -> { failures.message }
    end
  end
end
