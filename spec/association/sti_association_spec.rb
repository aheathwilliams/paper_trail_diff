# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :sti_badges, force: true do |table|
    table.string :type
    table.string :label, null: false
    table.integer :sti_owner_id
    table.timestamps null: false
  end

  create_table :sti_badge_notes, force: true do |table|
    table.string :body, null: false
    table.integer :sti_badge_id
    table.timestamps null: false
  end
end

class StiBadge < ActiveRecord::Base
  belongs_to :sti_owner, optional: true
  has_many :notes, class_name: 'StiBadgeNote'
  has_paper_trail
end

class StiBadgeNote < ActiveRecord::Base
  belongs_to :sti_badge, optional: true
  has_paper_trail
end

class StiPinnedBadge < StiBadge
end

class StiStarredBadge < StiPinnedBadge
end

class StiOwner < ActiveRecord::Base
  self.table_name = 'tracked_articles'
  has_many :badges, class_name: 'StiBadge', foreign_key: :sti_owner_id
  has_many :pinned_badges, class_name: 'StiPinnedBadge', foreign_key: :sti_owner_id
  has_paper_trail
end

# Children are found by key across the whole table, so the history of an
# association to an STI subclass must leave out its siblings, as the live
# association does.
RSpec.describe 'An association to an STI subclass' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [StiBadgeNote, StiBadge, StiOwner].each(&:delete_all)
  end

  def checkpoint(owner)
    StiOwner.transaction { StiOwner.find(owner.id).paper_trail.save_with_version }
    owner.versions.reorder(:created_at, :id).last
  end

  def labels(snapshot, name)
    snapshot.associations.fetch(name).records.map { |badge| badge.attributes['label'] }.sort
  end

  def badge_steps(steps)
    steps.filter_map do |step|
      association = step.diff.associations['pinned_badges']
      next unless association

      [step.from_boundary.item_type, step.from_boundary.item_id,
       association.added.map { |badge| badge.attributes['label'] },
       association.removed.map { |badge| badge.attributes['label'] },
       association.changed.map { |change| change.attributes.fetch('label').to_h }]
    end
  end

  it 'holds only the subclass and its descendants at every endpoint' do
    owner = StiOwner.create!(title: 'Owner')
    from = checkpoint(owner)
    StiBadge.create!(label: 'plain', sti_owner_id: owner.id)
    StiPinnedBadge.create!(label: 'pinned', sti_owner_id: owner.id)
    StiStarredBadge.create!(label: 'starred', sti_owner_id: owner.id)
    to = checkpoint(owner)
    expected = owner.reload.pinned_badges.map(&:label).sort
    paths = { associations: %i[pinned_badges badges] }

    results = [
      PaperTrailDiff.analyze(owner, from: from, to: to, **paths),
      PaperTrailDiff.analyze(owner, from: from, to: to, activity: true, **paths),
      PaperTrailDiff.analyze(owner, from: from, to: owner, **paths),
      PaperTrailDiff.analyze(owner, from: from, to: owner, activity: true, **paths)
    ]

    expect(expected).to eq(%w[pinned starred])
    expect(results.map { |result| labels(result.to_snapshot, 'pinned_badges') })
      .to all(eq(expected))
    expect(results.map { |result| labels(result.to_snapshot, 'badges') })
      .to all(eq(%w[pinned plain starred]))
    expect(results.map { |result| result.diff.associations.fetch('pinned_badges').added.length })
      .to all(eq(2))
  end

  it 'opens no activity step for a sibling and reports only the subclass' do
    owner = StiOwner.create!(title: 'Owner')
    plain = StiBadge.create!(label: 'plain', sti_owner: owner)
    pinned = StiPinnedBadge.create!(label: 'pinned', sti_owner: owner)
    from = checkpoint(owner)
    start = Time.now.utc
    plain.update!(label: 'plain 2')
    pinned.update!(label: 'pinned 2')
    plain.update!(label: 'plain 3')
    to = checkpoint(owner)
    window = start..Time.now.utc
    paths = { associations: %i[pinned_badges] }

    timelines = [
      PaperTrailDiff.activity_timeline(owner, from: from, to: to, **paths),
      PaperTrailDiff.activity_timeline(owner, from: from, to: owner, **paths),
      PaperTrailDiff.activity_timeline(owner, within: window, **paths),
      PaperTrailDiff.analyze_many([owner], within: window, activity: true, **paths)
                    .values.first.activity_timeline
    ]

    expect(timelines.map { |steps| steps.map { |step| step.from_boundary.item_id } })
      .to all(satisfy { |ids| !ids.include?(plain.id) })
    expected = [['StiBadge', pinned.id, [], [], [{ from: 'pinned', to: 'pinned 2' }]]]
    expect(timelines.map { |steps| badge_steps(steps) }).to all(eq(expected))
  end

  it 'adds and removes a row whose type moves it into or out of the subclass' do
    owner = StiOwner.create!(title: 'Owner')
    joining = StiBadge.create!(label: 'joining', sti_owner: owner)
    leaving = StiPinnedBadge.create!(label: 'leaving', sti_owner: owner)
    from = checkpoint(owner)
    start = Time.now.utc
    StiBadge.find(joining.id).update!(type: 'StiStarredBadge')
    StiBadge.find(leaving.id).update!(type: nil)
    to = checkpoint(owner)
    window = start..Time.now.utc
    paths = { associations: %i[pinned_badges] }

    timelines = [
      PaperTrailDiff.activity_timeline(owner, from: from, to: to, **paths),
      PaperTrailDiff.activity_timeline(owner, from: from, to: owner, **paths),
      PaperTrailDiff.activity_timeline(owner, within: window, **paths)
    ]

    expected = [['StiBadge', joining.id, ['joining'], [], []],
                ['StiBadge', leaving.id, [], ['leaving'], []]]
    expect(timelines.map { |steps| badge_steps(steps) }).to all(eq(expected))
  end

  it 'replaces a row whose type changes in the step of its own version' do
    owner = StiOwner.create!(title: 'Owner')
    badge = StiBadge.create!(label: 'badge', sti_owner: owner)
    from = checkpoint(owner)
    start = Time.now.utc
    StiBadge.find(badge.id).update!(type: 'StiPinnedBadge')
    to = checkpoint(owner)
    paths = { associations: %i[badges] }

    timelines = [
      PaperTrailDiff.activity_timeline(owner, from: from, to: to, **paths),
      PaperTrailDiff.activity_timeline(owner, within: start..Time.now.utc, **paths)
    ]

    expect(timelines.map do |steps|
      steps.filter_map do |step|
        association = step.diff.associations['badges']
        next unless association

        [step.from_boundary.item_id, association.removed.map(&:type), association.added.map(&:type)]
      end
    end).to all(eq([[badge.id, ['StiBadge'], ['StiPinnedBadge']]]))
  end

  it "opens no activity step for a sibling's children" do
    owner = StiOwner.create!(title: 'Owner')
    plain_note = StiBadge.create!(label: 'plain', sti_owner: owner).notes.create!(body: 'plain')
    pinned_note = StiPinnedBadge.create!(label: 'pinned', sti_owner: owner)
                                .notes.create!(body: 'pinned')
    start = Time.now.utc
    plain_note.update!(body: 'plain 2')
    pinned_note.update!(body: 'pinned 2')

    steps = PaperTrailDiff.activity_timeline(
      owner, within: start..Time.now.utc, associations: ['pinned_badges.notes']
    )

    expect(steps.map { |step| [step.from_boundary.item_type, step.from_boundary.item_id] })
      .to eq([['StiBadgeNote', pinned_note.id]])
  end
end
