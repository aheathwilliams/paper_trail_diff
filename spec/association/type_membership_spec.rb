# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :tm_items, force: true do |table|
    table.string :type
    table.string :name, null: false
    table.integer :blocked_by_id
    table.integer :tm_project_id
    table.timestamps null: false
  end

  create_table :tm_projects, force: true do |table|
    table.string :type
    table.string :name, null: false
    table.integer :parent_id
    table.timestamps null: false
  end

  create_table :tm_notes, force: true do |table|
    table.string :body, null: false
    table.string :notable_type
    table.integer :notable_id
    table.integer :tm_person_id
    table.timestamps null: false
  end

  create_table :tm_people, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end
end

class TmItem < ActiveRecord::Base
  belongs_to :blocked_by, class_name: 'TmItem', optional: true
  belongs_to :blocking_bug, class_name: 'TmBug', foreign_key: :blocked_by_id, optional: true
  belongs_to :tm_project, optional: true
  has_many :blocking, class_name: 'TmItem', foreign_key: :blocked_by_id
  has_paper_trail
end

class TmBug < TmItem
end

class TmProject < ActiveRecord::Base
  belongs_to :parent, class_name: 'TmProject', optional: true
  has_many :sub_projects, class_name: 'TmProject', foreign_key: :parent_id
  has_many :tm_items
  has_many :notes, class_name: 'TmNote', as: :notable
  has_paper_trail
end

class TmSubProject < TmProject
end

class TmNote < ActiveRecord::Base
  belongs_to :notable, polymorphic: true, optional: true
  belongs_to :tm_person, optional: true
  has_paper_trail
end

class TmPerson < ActiveRecord::Base
  has_many :notes, class_name: 'TmNote'
  has_many :noted_items, through: :notes, source: :notable, source_type: 'TmItem'
  has_paper_trail
end

# The type columns decide membership as Active Record's own queries do: a
# class's STI type condition, an `as:` owner's polymorphic name and a
# through's `source_type:`. A batch of roots of several classes of one table
# reads each as it is read alone.
RSpec.describe 'Membership by type' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TmNote, TmItem, TmProject, TmPerson].each(&:delete_all)
  end

  def ids(snapshot, name)
    snapshot.associations.fetch(name).records.map(&:id)
  end

  def steps(analysis)
    analysis.activity_timeline.map { |step| [step.source_boundary.version_id, step.diff.to_h] }
  end

  describe 'a belongs_to to an STI subclass' do
    it 'reads no row of another class, as Active Record reads none' do
      item = TmItem.create!(name: 'item')
      other = TmItem.create!(name: 'blocker')
      item.update!(blocked_by: other)
      item.update!(name: 'renamed')
      other.update!(name: 'blocker renamed')

      expect(TmItem.find(item.id).blocking_bug).to be_nil
      version = item.versions.reorder(:id).last
      analysis = PaperTrailDiff.analyze(item, from: version, to: item, associations: [:blocking_bug])
      expect(ids(analysis.from_snapshot, 'blocking_bug')).to eq([])
      expect(analysis.diff.associations).to eq({})
      steps = PaperTrailDiff.activity_timeline(item, associations: [:blocking_bug])
      expect(steps.flat_map { |step| step.diff.associations.keys }).to eq([])
    end

    it 'reads the row while it is of that class' do
      item = TmItem.create!(name: 'item')
      bug = TmBug.create!(name: 'bug')
      item.update!(blocked_by_id: bug.id)
      item.update!(name: 'renamed')
      bug.update!(type: 'TmItem')
      item.update!(name: 'again')

      versions = item.versions.reorder(:id).to_a
      diff = PaperTrailDiff.compare(versions[2], item, associations: [:blocking_bug])
      relationship = diff.to_h.dig(:associations, 'blocking_bug', :relationship)
      expect([relationship.dig(:from, :id), relationship[:to]]).to eq([bug.id, nil])
    end
  end

  describe 'an `as:` child' do
    it "is a member only while its type is the owner's polymorphic name" do
      project = TmSubProject.create!(name: 'project')
      note = TmNote.create!(body: 'note', notable_type: 'TmSubProject', notable_id: project.id)
      project.update!(name: 'renamed')
      note.update!(notable_type: 'TmProject')
      project.update!(name: 'again')

      expect(TmProject.find(project.id).notes.map(&:id)).to eq([note.id])
      versions = project.versions.reorder(:id).to_a
      analysis = PaperTrailDiff.analyze(project, from: versions[1], to: project, associations: [:notes])
      expect(ids(analysis.from_snapshot, 'notes')).to eq([])
      expect(ids(analysis.to_snapshot, 'notes')).to eq([note.id])
      steps = PaperTrailDiff.activity_timeline(project, associations: [:notes])
      expect(steps.map { |step| step.diff.associations['notes']&.added&.map(&:id) }.compact)
        .to eq([[note.id]])
    end
  end

  describe 'a through with source_type' do
    it 'descends only into targets of that type' do
      person = TmPerson.create!(name: 'person')
      blocker = TmItem.create!(name: 'blocker')
      item = TmItem.create!(name: 'item', blocked_by: blocker)
      TmNote.create!(body: 'item note', notable: item, tm_person: person)
      TmNote.create!(body: 'project note', notable: TmProject.create!(name: 'project'),
                     tm_person: person)

      steps = PaperTrailDiff.activity_timeline(person, associations: ['noted_items.blocked_by'])
      expect(steps.length).to eq(2)
    end
  end

  describe 'a batch of roots of several classes of one table' do
    it 'reads a root that stands in another root of a subclass as analyze does' do
      first = TmItem.create!(name: 'first')
      second = TmItem.create!(name: 'second', blocked_by: first)
      bug = TmBug.create!(name: 'bug', blocked_by: second)
      bug.update!(name: 'renamed')

      options = { associations: [:blocking], activity: true }
      single = PaperTrailDiff.analyze(second, **options)
      batch = PaperTrailDiff.analyze_many([second, bug], **options).fetch(['TmItem', second.id.to_s])
      expect(steps(batch)).to eq(steps(single))
    end
  end

  describe 'a windowed batch' do
    # The later root has no version in the window, but one after it, so its
    # row now is not its state in the window.
    it 'reads a root that stands in another root at its state in the window' do
      parent = TmProject.create!(name: 'parent')
      from = Time.now.utc
      child = TmProject.create!(name: 'child', parent: parent)
      child.update!(name: 'renamed')
      to = child.versions.reorder(:id).last.created_at
      parent.update!(name: 'parent renamed')
      parent.update!(parent: child)

      options = { within: from..to, associations: ['sub_projects.parent'] }
      roots = [child, parent].map(&:reload)
      single = PaperTrailDiff.analyze(roots.first, **options)
      batch = PaperTrailDiff.analyze_many(roots, **options).fetch(['TmProject', child.id.to_s])
      expect(batch.timeline.map { |step| step.diff.to_h })
        .to eq(single.timeline.map { |step| step.diff.to_h })
    end
  end
end
