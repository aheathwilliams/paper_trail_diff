# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :uv_orgs, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :uv_projects, force: true do |table|
    table.string :name, null: false
    table.integer :uv_org_id
    table.timestamps null: false
  end

  create_table :uv_tasks, force: true do |table|
    table.string :title, null: false
    table.integer :uv_project_id
    table.timestamps null: false
  end
end

class UvOrg < ActiveRecord::Base
  has_many :uv_projects
  has_many :uv_tasks, through: :uv_projects
  has_paper_trail
end

class UvProject < ActiveRecord::Base
  belongs_to :uv_org, optional: true
  has_many :uv_tasks
  has_paper_trail
end

class UvTask < ActiveRecord::Base
  belongs_to :uv_project, optional: true
  has_paper_trail
end

# A row saved before PaperTrail has no version to name its owner, so it
# holds its live key throughout, and a change below it selects that owner.
RSpec.describe 'Selecting a root through a row without versions' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [UvTask, UvProject, UvOrg].each(&:delete_all)
  end

  def old_tree
    PaperTrail.request(enabled: false) do
      org = UvOrg.create!(name: 'org')
      project = UvProject.create!(name: 'project', uv_org: org)
      [org, project, UvTask.create!(title: 'task', uv_project: project)]
    end
  end

  %w[uv_projects.uv_tasks uv_tasks].each do |path|
    it "selects the root of a task edited under it, over #{path}" do
      org, _project, task = old_tree
      org.update!(name: 'org, edited')
      UvOrg.create!(name: 'other').update!(name: 'other, edited')
      since = Time.now.utc
      task.update!(title: 'edited')

      report = PaperTrailDiff.report(UvOrg.all, since: since, limit: 5, associations: [path])

      expect(report.roots).to eq([org])
      scoped = PaperTrailDiff.analyze_scope(UvOrg.all, within: since.., limit: 5,
                                                       associations: [path], activity: true)
      expect(scoped.roots).to eq([org])
    end
  end

  it 'selects no root for a row with a version that left it' do
    org, project, task = old_tree
    org.update!(name: 'org, edited')
    other = UvOrg.create!(name: 'other')
    project.update!(uv_org: other)
    since = Time.now.utc
    task.update!(title: 'edited')

    report = PaperTrailDiff.report(UvOrg.all, since: since, limit: 5,
                                              associations: %w[uv_projects.uv_tasks])

    expect(report.roots).to eq([other])
  end

  def roots(since, path, within: since..)
    report = PaperTrailDiff.report(UvOrg.all, since: since, limit: 5, associations: [path])
    scoped = PaperTrailDiff.analyze_scope(UvOrg.all, within: within, limit: 5,
                                                     associations: [path], activity: true)
    [report.roots.sort_by(&:id), scoped.roots.sort_by(&:id)]
  end

  # The first version of a row from before PaperTrail is the update that
  # moves it: PT-AT's row for it names the new owner, and only its stored
  # state names the one it left.
  it 'selects the root a row left with its first version' do
    org, project, _task = old_tree
    other = UvOrg.create!(name: 'other')
    since = Time.now.utc
    project.update!(uv_org: other)

    expect(roots(since, 'uv_projects')).to eq([[org, other], [org, other]])
  end

  it 'selects the root a row was detached from with its first version' do
    org, project, _task = old_tree
    since = Time.now.utc
    project.update!(uv_org: nil)

    expect(roots(since, 'uv_projects')).to eq([[org], [org]])
  end

  %w[uv_projects.uv_tasks uv_tasks].each do |path|
    it "selects the root of the row a task left with its first version, over #{path}" do
      org, _project, task = old_tree
      other = UvOrg.create!(name: 'other')
      moved_to = UvProject.create!(name: 'new project', uv_org: other)
      since = Time.now.utc
      task.update!(uv_project: moved_to)

      expect(roots(since, path)).to eq([[org, other], [org, other]])
    end
  end

  # The row held its owner until that version, so through the whole window.
  it 'selects the root a row held through a window its first version came after' do
    org, project, task = old_tree
    other = UvOrg.create!(name: 'other')
    start = Time.now.utc
    task.update!(title: 'edited')
    finish = Time.now.utc
    project.update!(uv_org: other)

    paths = %w[uv_projects.uv_tasks]
    scoped = PaperTrailDiff.analyze_scope(UvOrg.all, within: start..finish, limit: 5,
                                                     associations: paths, activity: true)

    expect(scoped.roots).to eq([org])
  end

  it 'reads no stored state for a row whose first version came before the window' do
    org, project, _task = old_tree
    other = UvOrg.create!(name: 'other')
    project.update!(name: 'renamed')
    since = Time.now.utc
    project.update!(uv_org: other)

    expect(roots(since, 'uv_projects')).to eq([[org, other], [org, other]])
  end
end
