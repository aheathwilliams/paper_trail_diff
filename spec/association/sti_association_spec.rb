# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :sti_badges, force: true do |table|
    table.string :type
    table.string :label, null: false
    table.integer :sti_owner_id
    table.timestamps null: false
  end
end

class StiBadge < ActiveRecord::Base
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
    [StiBadge, StiOwner].each(&:delete_all)
  end

  def checkpoint(owner)
    StiOwner.transaction { StiOwner.find(owner.id).paper_trail.save_with_version }
    owner.versions.reorder(:created_at, :id).last
  end

  def labels(snapshot, name)
    snapshot.associations.fetch(name).records.map { |badge| badge.attributes['label'] }.sort
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
end
