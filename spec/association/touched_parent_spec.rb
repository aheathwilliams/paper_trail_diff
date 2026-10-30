# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :touched_parents, force: true do |table|
    table.string :title, null: false
    table.timestamps null: false
  end

  create_table :touched_children, force: true do |table|
    table.integer :parent_id, null: false
    table.string :name, null: false
    table.timestamps null: false
  end
end

class TouchedParent < ActiveRecord::Base
  has_many :children, class_name: 'TouchedChild', foreign_key: :parent_id, inverse_of: :parent
  has_paper_trail
end

class TouchedChild < ActiveRecord::Base
  belongs_to :parent, class_name: 'TouchedParent', touch: true, inverse_of: :children
  has_paper_trail
end

# `touch: true` saves a parent version in the transaction of every child save,
# after the child's own version. PT-AT rebuilds that parent version's children
# as they were before the transaction, so a range ending there ends before the
# child change too.
RSpec.describe 'Activity for a parent touched by its children' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    TouchedChild.delete_all
    TouchedParent.delete_all
  end

  def history
    parent = TouchedParent.create!(title: 'Root')
    child = parent.children.create!(name: 'before')
    child.update!(name: 'after')
    [parent.reload, child]
  end

  def name_changes(steps)
    steps.filter_map do |step|
      change = step.diff.associations['children']&.changed&.first
      [step.source_boundary.item_type, change.attributes.fetch('name').to_h] if change
    end
  end

  it 'ends a range at a touch version before the child change it was saved with' do
    parent, child = history
    from = parent.versions.first
    to = parent.versions.last

    steps = PaperTrailDiff.activity_timeline(parent, from: from, to: to, associations: [:children],
                                                     snapshots: true)
    analysis = PaperTrailDiff.analyze(parent, from: from, to: to, associations: [:children])

    expect(steps.map { |step| step.source_boundary.version_id })
      .not_to include(child.versions.last.id)
    expect(name_changes(steps)).to eq([])
    expect(steps.last.to_snapshot.to_h).to eq(analysis.to_snapshot.to_h)
    expect(analysis.to_snapshot.associations.fetch('children').records.map do |record|
      record.attributes.fetch('name')
    end).to eq(['before'])
  end

  # The other half of the split: a range starting at the touch version starts
  # before its transaction too, so the child change saved just before it is
  # inside. Read from that point alone, the child was already changed, and the
  # change was in neither part of a history split there.
  it 'starts a range at a touch version before the child change it was saved with' do
    parent, = history
    touch = parent.versions.last
    parent.update!(title: 'Later')
    later = parent.versions.last
    changes = [later, parent].map do |to|
      diff = PaperTrailDiff.compare(touch, to, associations: [:children])
      diff.associations.fetch('children').changed.map { |record| record.attributes['name'].to_h }
    end

    expect(changes).to eq([[{ from: 'before', to: 'after' }]] * 2)
    steps = PaperTrailDiff.activity_timeline(parent, from: touch, to: later,
                                                     associations: [:children], group: :transaction)
    expect(name_changes(steps)).to eq([['TouchedChild', { from: 'before', to: 'after' }]])
  end

  it 'credits the change to the child when the range reaches past the touch' do
    parent, child = history
    steps = PaperTrailDiff.activity_timeline(parent, from: parent.versions.first,
                                                     associations: [:children],
                                                     group: :transaction)

    expect(name_changes(steps)).to eq([['TouchedChild', { from: 'before', to: 'after' }]])
    expect(steps.last.source_boundary.version_id).to eq(child.versions.last.id)
  end
end
