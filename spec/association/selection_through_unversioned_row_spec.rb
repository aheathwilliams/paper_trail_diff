# frozen_string_literal: true

require_relative '../support/association_database'
require_relative '../support/source_type_database'

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
    table.integer :uv_label_id
    table.references :subject, polymorphic: true
    table.timestamps null: false
  end

  create_table :uv_labels, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end
end

class UvLabel < ActiveRecord::Base
  has_paper_trail
end

class UvOrg < ActiveRecord::Base
  has_many :uv_projects
  has_many :uv_tasks, through: :uv_projects
  has_paper_trail
end

class UvProject < ActiveRecord::Base
  belongs_to :uv_org, optional: true
  has_many :uv_tasks
  has_many :uv_labels, through: :uv_tasks
  has_paper_trail
end

class UvTask < ActiveRecord::Base
  belongs_to :uv_project, optional: true
  belongs_to :uv_label, optional: true
  belongs_to :subject, polymorphic: true, optional: true
  has_paper_trail
end

# A row saved before PaperTrail has no version to name its owner, so it
# holds its live key throughout, and a change below it selects that owner.
RSpec.describe 'Selecting a root through a row without versions' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [UvTask, UvProject, UvOrg, UvLabel, SourceTypeLink, SourceTypeHolder, SourceTypeAuthor,
     SourceTypeTag].each(&:delete_all)
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

  # PT-AT records a belongs_to on the owner's own versions, so an owner
  # without any is in none of its rows, and holds its live key throughout.
  describe 'when the row without versions is the one that points at the change' do
    def unversioned(&block)
      PaperTrail.request(enabled: false, &block)
    end

    def labelled(label)
      unversioned do
        org = UvOrg.create!(name: 'org')
        project = UvProject.create!(name: 'project', uv_org: org)
        [org, project, UvTask.create!(title: 'task', uv_project: project, uv_label: label)]
      end
    end

    def selected(scope, since, path)
      report = PaperTrailDiff.report(scope, since: since, limit: 5, associations: [path])
      scoped = PaperTrailDiff.analyze_scope(scope, within: since.., limit: 5,
                                                   associations: [path], activity: true)
      [report.roots.sort_by(&:id), scoped.roots.sort_by(&:id)]
    end

    it 'selects a root without versions whose target changed' do
      label = UvLabel.create!(name: 'label')
      _org, _project, task = labelled(label)
      labelled(UvLabel.create!(name: 'quiet'))
      since = Time.now.utc
      label.update!(name: 'renamed')

      expect(selected(UvTask.all, since, 'uv_label')).to eq([[task], [task]])
      report = PaperTrailDiff.report(UvTask.all, since: since, limit: 5, associations: ['uv_label'])
      change = report.analysis_for(task).diff.associations.fetch('uv_label').changed
      expect(change.attributes.fetch('name').to_h).to eq({ from: 'label', to: 'renamed' })
    end

    it 'selects a root without versions over a change below its target' do
      org, project, task = old_tree
      since = Time.now.utc
      org.update!(name: 'renamed')

      expect(selected(UvTask.all, since, 'uv_project.uv_org')).to eq([[task], [task]])
      expect(selected(UvProject.all, since, 'uv_org')).to eq([[project], [project]])
    end

    it 'selects the root above a row without versions whose target changed' do
      label = UvLabel.create!(name: 'label')
      org, project, _task = labelled(label)
      labelled(UvLabel.create!(name: 'quiet'))
      since = Time.now.utc
      label.update!(name: 'renamed')

      expect(selected(UvOrg.all, since, 'uv_projects.uv_tasks.uv_label')).to eq([[org], [org]])
      expect(selected(UvProject.all, since, 'uv_tasks.uv_label')).to eq([[project], [project]])
    end

    it 'selects the root of a join row without versions whose target changed' do
      label = UvLabel.create!(name: 'label')
      _org, project, _task = labelled(label)
      labelled(UvLabel.create!(name: 'quiet'))
      since = Time.now.utc
      label.update!(name: 'renamed')

      expect(selected(UvProject.all, since, 'uv_labels')).to eq([[project], [project]])
    end

    # An analysis reads the row once no version follows, so the key the bulk
    # write gave it is the one it holds through the window.
    it 'selects a root whose key was changed without a version after its last one' do
      label = UvLabel.create!(name: 'label')
      other = UvLabel.create!(name: 'other')
      _org, _project, task = labelled(label)
      task.update!(uv_label: other)
      UvTask.where(id: task.id).update_all(uv_label_id: label.id)
      since = Time.now.utc
      label.update!(name: 'renamed')

      expect(selected(UvTask.all, since, 'uv_label')).to eq([[task], [task]])
    end

    it 'selects a root without versions by its polymorphic target, under its type' do
      label = UvLabel.create!(id: 700, name: 'label')
      other = UvOrg.create!(id: 700, name: 'org')
      on_label = unversioned { UvTask.create!(title: 'on label', subject: label) }
      unversioned { UvTask.create!(title: 'on org', subject: other) }
      since = Time.now.utc
      label.update!(name: 'renamed')

      expect(selected(UvTask.all, since, 'subject')).to eq([[on_label], [on_label]])
    end

    it 'selects the root of a typed join row without versions whose target changed' do
      author = SourceTypeAuthor.create!(id: 700, name: 'author')
      tag = SourceTypeTag.create!(id: 700, name: 'tag')
      holder, tagged = unversioned do
        Array.new(2) { |index| SourceTypeHolder.create!(name: "holder #{index}") }
      end
      unversioned do
        SourceTypeLink.create!(holder: holder, target: author)
        SourceTypeLink.create!(holder: tagged, target: tag)
      end
      since = Time.now.utc
      author.update!(name: 'renamed')

      expect(selected(SourceTypeHolder.all, since, 'linked_authors')).to eq([[holder], [holder]])
    end
  end
end
