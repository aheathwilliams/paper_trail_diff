# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :sti_child_badges, force: true do |table|
    table.string :type
    table.string :label, null: false
    table.timestamps null: false
  end

  create_table :sti_child_notes, force: true do |table|
    table.string :body, null: false
    table.integer :badge_id
    table.timestamps null: false
  end

  create_table :sti_child_comments, force: true do |table|
    table.string :body, null: false
    table.integer :note_id
    table.timestamps null: false
  end
end

class StiChildBadge < ActiveRecord::Base
  has_paper_trail
end

class StiChildPinnedBadge < StiChildBadge
end

class StiChildNote < ActiveRecord::Base
  belongs_to :badge, class_name: 'StiChildBadge', optional: true
  has_paper_trail
end

class StiChildComment < ActiveRecord::Base
  belongs_to :note, class_name: 'StiChildNote', optional: true
  has_paper_trail
end

# The versions table has no `item_subtype` column, so a target's version
# names only the STI base class, while its snapshot carries the subclass.
# Activity must still find the target it replaces.
RSpec.describe 'Activity on an STI belongs_to target' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [StiChildComment, StiChildNote, StiChildBadge].each(&:delete_all)
  end

  def checkpoint(record)
    record.class.transaction { record.class.find(record.id).paper_trail.save_with_version }
    record.versions.reorder(:created_at, :id).last
  end

  def side(snapshot)
    snapshot && [snapshot.type, snapshot.attributes['label']]
  end

  def relationship(change)
    change.relationship && [side(change.relationship.from), side(change.relationship.to)]
  end

  # The badge change of every activity step, and the net change of the
  # checkpoint and activity analyses, which must agree.
  def badge_changes(root, path: :badge)
    from = checkpoint(root)
    yield
    to = checkpoint(root)
    options = { from: from, to: to, associations: [path] }
    checkpoints = PaperTrailDiff.analyze(root, **options)
    activity = PaperTrailDiff.analyze(root, **options, activity: true, snapshots: true)
    steps = activity.activity_timeline.filter_map { |step| badge_change(step.diff) }
    expect(activity.to_snapshot.to_h).to eq(checkpoints.to_snapshot.to_h)
    [badge_change(checkpoints.diff), badge_change(activity.diff), steps]
  end

  def badge_change(diff)
    note = diff.associations['note']&.changed
    change = diff.associations['badge'] || note&.associations&.[]('badge')
    change && relationship(change)
  end

  it 'removes a destroyed subclass target' do
    badge = StiChildPinnedBadge.create!(label: 'pinned')
    note = StiChildNote.create!(body: 'note', badge: badge)
    expected = [%w[StiChildPinnedBadge pinned], nil]

    expect(badge_changes(note) { badge.destroy! }).to eq([expected, expected, [expected]])
  end

  it 'replaces a target that becomes a subclass' do
    badge = StiChildBadge.create!(label: 'plain')
    note = StiChildNote.create!(body: 'note', badge: badge)
    expected = [%w[StiChildBadge plain], %w[StiChildPinnedBadge pinned]]

    changes = badge_changes(note) do
      StiChildBadge.find(badge.id).update!(type: 'StiChildPinnedBadge', label: 'pinned')
    end

    expect(changes).to eq([expected, expected, [expected]])
  end

  it 'replaces a target that stops being a subclass' do
    badge = StiChildPinnedBadge.create!(label: 'pinned')
    note = StiChildNote.create!(body: 'note', badge: badge)
    expected = [%w[StiChildPinnedBadge pinned], %w[StiChildBadge plain]]

    changes = badge_changes(note) do
      StiChildBadge.find(badge.id).update!(type: nil, label: 'plain')
    end

    expect(changes).to eq([expected, expected, [expected]])
  end

  it 'removes a destroyed subclass target further down a path' do
    badge = StiChildPinnedBadge.create!(label: 'pinned')
    comment = StiChildComment.create!(
      body: 'comment', note: StiChildNote.create!(body: 'note', badge: badge)
    )
    expected = [%w[StiChildPinnedBadge pinned], nil]

    expect(badge_changes(comment, path: 'note.badge') { badge.destroy! })
      .to eq([expected, expected, [expected]])
  end

  it 'keeps the edit of a subclass target as a change to it' do
    badge = StiChildPinnedBadge.create!(label: 'pinned')
    note = StiChildNote.create!(body: 'note', badge: badge)
    from = checkpoint(note)
    badge.update!(label: 'pinned 2')
    to = checkpoint(note)

    change = PaperTrailDiff.analyze(note, from: from, to: to, activity: true,
                                          associations: [:badge]).diff.associations.fetch('badge')

    expect(change.relationship).to be_nil
    expect([change.changed.record.type, change.changed.attributes.fetch('label').to_h])
      .to eq(['StiChildPinnedBadge', { from: 'pinned', to: 'pinned 2' }])
  end

  describe PaperTrailDiff::ActivityEventRecordResolver do
    def state_after(version)
      described_class.new.record_after(version, direct: true)
    end

    it 'builds a subclass row as its subclass without prepared history' do
      badge = StiChildPinnedBadge.create!(label: 'pinned')
      badge.update!(label: 'pinned 2')
      created, updated = badge.versions.reorder(:id).to_a

      expect([state_after(created), state_after(updated)]
               .map { |state| [state.model_class, state.attributes['label']] })
        .to eq([[StiChildPinnedBadge, 'pinned'], [StiChildPinnedBadge, 'pinned 2']])
    end

    it 'builds a row as the class its type changes to' do
      badge = StiChildPinnedBadge.create!(label: 'pinned')
      StiChildBadge.find(badge.id).update!(type: nil)
      badge = StiChildBadge.find(badge.id)
      badge.update!(type: 'StiChildPinnedBadge')

      expect(badge.versions.reorder(:id).drop(1).map { |version| state_after(version).model_class })
        .to eq([StiChildBadge, StiChildPinnedBadge])
    end

    it 'leaves a type that names no class to the reified record' do
      badge = StiChildBadge.create!(label: 'plain')
      badge.update!(label: 'plain 2')
      version = badge.versions.reorder(:id).last
      retyped = version.object_changes.sub('label:', "type:\n- \n- StiChildGoneBadge\nlabel:")
      version.update_column(:object_changes, retyped)

      expect { state_after(version) }.not_to raise_error
      expect(described_class.new.send(:direct_record_after, version)).to be_nil
    end
  end
end
