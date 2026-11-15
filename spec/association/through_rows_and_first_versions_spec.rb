# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :tf_projects, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :tf_users, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :tf_tasks, force: true do |table|
    table.string :title, null: false
    table.integer :tf_project_id
    table.timestamps null: false
  end

  create_table :tf_pins, force: true do |table|
    table.string :label, null: false
    table.integer :tf_project_id
    table.integer :tf_user_id
    table.timestamps null: false
  end

  create_table :tf_memberships, force: true do |table|
    table.string :role
    table.integer :tf_project_id
    table.integer :tf_user_id
    table.timestamps null: false
  end

  create_table :tf_notes, force: true do |table|
    table.string :body, null: false
    table.integer :tf_user_id
    table.timestamps null: false
  end
end

class TfProject < ActiveRecord::Base
  has_many :tf_tasks
  has_one :pin, class_name: 'TfPin'
  has_one :pin_user, through: :pin, source: :tf_user
  has_many :tf_memberships
  has_many :members, through: :tf_memberships, source: :tf_user
  has_many :member_notes, through: :members, source: :tf_notes
  has_paper_trail
end

class TfUser < ActiveRecord::Base
  has_many :tf_notes
  has_many :tf_memberships
  has_many :projects, through: :tf_memberships, source: :tf_project
  has_paper_trail
end

class TfTask < ActiveRecord::Base
  belongs_to :tf_project, optional: true
  has_paper_trail
end

class TfPin < ActiveRecord::Base
  belongs_to :tf_project, optional: true
  belongs_to :tf_user, optional: true
  has_paper_trail
end

class TfMembership < ActiveRecord::Base
  belongs_to :tf_project, optional: true
  belongs_to :tf_user, optional: true
  has_paper_trail
end

class TfNote < ActiveRecord::Base
  belongs_to :tf_user, optional: true
  has_paper_trail
end

# PT-AT stores the keys a version saved, so a child made without a version
# names the owner it left only in its first version's state. A through joins
# every row of its parts, a has_one's too, and a join row that leads nowhere
# the root's tree shows is no step of it.
RSpec.describe 'Through rows and first versions',
               mutant_expression: %w[PaperTrailDiff::ActivityChildCandidateLoader
                                     PaperTrailDiff::ActivityTreeFilter
                                     PaperTrailDiff::BatchPreload
                                     PaperTrailDiff::PreparedActivityIndex
                                     PaperTrailDiff::PreparedHistory
                                     PaperTrailDiff::PreparedStateAssociationReader] do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TfNote, TfMembership, TfPin, TfTask, TfUser, TfProject].each(&:delete_all)
  end

  def as(who, &block)
    PaperTrail.request(whodunnit: who) { ActiveRecord::Base.transaction(&block) }
  end

  def ids(snapshot, name)
    snapshot.associations.fetch(name).records.map(&:id)
  end

  def authors(steps, type = nil)
    steps.select { |step| type.nil? || step.source_boundary.item_type == type }
         .map { |step| step.source_boundary.whodunnit }
  end

  describe 'a child made without a version' do
    it 'is under the owner it left until its first version moves it' do
      left = TfProject.create!(name: 'left')
      joined = TfProject.create!(name: 'joined')
      task = PaperTrail.request(enabled: false) { TfTask.create!(title: 'old', tf_project: left) }
      left.update!(name: 'left 2')
      before_move = left.versions.last
      as('bob') { task.update!(tf_project: joined) }
      left.update!(name: 'left 3')

      analysis = PaperTrailDiff.analyze(left, from: before_move, to: left,
                                              associations: %w[tf_tasks], activity: true)
      expect(ids(analysis.from_snapshot, 'tf_tasks')).to eq([task.id])
      expect(ids(analysis.to_snapshot, 'tf_tasks')).to eq([])
      expect(authors(analysis.activity_timeline, 'TfTask')).to eq(['bob'])
      expect(PaperTrailDiff.compare(before_move, left, associations: %w[tf_tasks])
        .associations.fetch('tf_tasks').removed.map(&:id)).to eq([task.id])
    end
  end

  describe 'a has_one through a has_one' do
    it 'reads the user of any pin, as its one query joins them all' do
      user = TfUser.create!(name: 'u')
      project = TfProject.create!(name: 'p')
      TfPin.create!(tf_project: project, label: 'first, no user')
      project.update!(name: 'p2')
      as('bob') { TfPin.create!(tf_project: project, tf_user: user, label: 'second') }
      project.update!(name: 'p3')
      project.reload

      expect(project.pin_user).to eq(user)
      analysis = PaperTrailDiff.analyze(project, associations: %w[pin_user], activity: true)
      expect(ids(analysis.to_snapshot, 'pin_user')).to eq([user.id])
      before_last = PaperTrailDiff.analyze(project, from: project.versions.last, to: project,
                                                    associations: %w[pin_user])
      expect(ids(before_last.from_snapshot, 'pin_user')).to eq([user.id])
      bob = analysis.activity_timeline.find { |step| step.source_boundary.whodunnit == 'bob' }
      expect(bob).not_to be_empty
    end

    # The join has no order, so which pin's user Active Record reads is the
    # database's choice: the first pin's on SQLite, PostgreSQL and MySQL,
    # the lowest user id on SQL Server. History reads the same one.
    it 'reads the user Active Record reads when two pins name one' do
      second_user, first_user = %w[later earlier].map { |name| TfUser.create!(name: name) }
      project = TfProject.create!(name: 'p')
      TfPin.create!(tf_project: project, tf_user: first_user, label: 'first')
      TfPin.create!(tf_project: project, tf_user: second_user, label: 'second')
      project.update!(name: 'p2')
      project.reload

      read = TfProject.connection.adapter_name == 'SQLServer' ? second_user : first_user
      expect(project.pin_user).to eq(read)
      analysis = PaperTrailDiff.analyze(project, from: project.versions.last, to: project,
                                                 associations: %w[pin pin_user])
      expect(ids(analysis.from_snapshot, 'pin_user')).to eq([read.id])
      expect(analysis.diff.associations).to be_empty
      expect(ids(PaperTrailDiff.analyze(project, associations: %w[pin_user]).to_snapshot,
                 'pin_user'))
        .to eq([read.id])
    end

    it 'makes no step of a pin that leads to no user' do
      user = TfUser.create!(name: 'u')
      project = TfProject.create!(name: 'p')
      TfPin.create!(tf_project: project, tf_user: user, label: 'first')
      project.update!(name: 'p2')
      extra = as('bob') { TfPin.create!(tf_project: project, label: 'second') }
      as('carol') { extra.update!(label: 'edited') }
      as('dave') { extra.destroy! }

      steps = SpecTimelines.activity_timeline(project, associations: %w[pin_user])
      expect(authors(steps) & %w[bob carol dave]).to eq([])
    end
  end

  describe 'join rows outside the tree' do
    it 'makes no step of a member before joining or after leaving' do
      project = TfProject.create!(name: 'p')
      other = TfProject.create!(name: 'other')
      user = TfUser.create!(name: 'u')
      as('early') { user.update!(name: 'renamed before joining') }
      membership = as('join') { TfMembership.create!(tf_project: project, tf_user: user) }
      as('note') { TfNote.create!(tf_user: user, body: 'n') }
      as('leave') { membership.update!(tf_project: other) }
      as('late') { user.update!(name: 'renamed after leaving') }

      steps = SpecTimelines.activity_timeline(project, associations: %w[member_notes])
      expect(authors(steps, 'TfUser')).to eq([])
      expect(authors(steps)).to include('note', 'leave')
    end

    it 'makes a step of a row one level down only while its owner is in the tree' do
      elsewhere = TfProject.create!(name: 'elsewhere')
      root = TfProject.create!(name: 'root')
      guest = TfUser.create!(name: 'guest')
      row = as('created elsewhere') { TfMembership.create!(tf_project: elsewhere, tf_user: guest) }
      as('edited elsewhere') { row.update!(role: 'x') }
      as('arrives') { row.update!(tf_project: root) }
      as('goes back') { row.update!(tf_project: elsewhere) }
      as('edited again') { row.update!(role: 'y') }

      steps = SpecTimelines.activity_timeline(root, associations: %w[members.projects])
      expect(authors(steps, 'TfMembership')).to eq(['arrives', 'goes back'])
    end
  end
end
