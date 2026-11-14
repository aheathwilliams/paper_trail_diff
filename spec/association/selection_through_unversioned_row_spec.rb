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
end
