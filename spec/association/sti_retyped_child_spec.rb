# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :rt_owners, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :rt_items, force: true do |table|
    table.string :type
    table.string :name, null: false
    table.integer :rt_owner_id
    table.timestamps null: false
  end

  create_table :rt_parts, force: true do |table|
    table.string :title, null: false
    table.integer :rt_item_id
    table.timestamps null: false
  end
end

class RtOwner < ActiveRecord::Base
  has_many :special_items, class_name: 'RtSpecialItem'
  has_paper_trail
end

class RtItem < ActiveRecord::Base
  belongs_to :rt_owner, optional: true
  has_paper_trail
end

# Only the subclass has parts.
class RtSpecialItem < RtItem
  has_many :parts, class_name: 'RtPart', foreign_key: :rt_item_id
end

class RtPart < ActiveRecord::Base
  belongs_to :rt_item, optional: true
  has_paper_trail
end

# A row retyped to its base class leaves an association to the subclass, and
# the paths below that association name what only the subclass has.
RSpec.describe 'A child retyped out of an STI subclass association and back' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [RtPart, RtItem, RtOwner].each(&:delete_all)
  end

  it 'reads the activity of the subclass association without raising' do
    owner = RtOwner.create!(name: 'o')
    item = RtSpecialItem.create!(name: 'i', rt_owner: owner)
    RtPart.create!(title: 'p', rt_item: item)
    RtItem.find(item.id).update!(type: nil)
    RtItem.find(item.id).update!(type: 'RtSpecialItem')
    owner.reload
    paths = %w[special_items.parts]

    analysis = PaperTrailDiff.analyze(owner, associations: paths, activity: true)
    items = analysis.to_snapshot.associations.fetch('special_items').records
    expect(items.map(&:id)).to eq([item.id])
    report = PaperTrailDiff.report(RtOwner.all, since: 1.day.ago, limit: 5, associations: paths)
    expect(report.roots).to eq([owner])
  end
end
