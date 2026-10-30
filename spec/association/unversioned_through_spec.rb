# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :loose_racks, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :loose_slots, force: true do |table|
    table.integer :loose_rack_id
    table.integer :loose_item_id
  end

  create_table :loose_items, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end
end

# The join model has no history, so past membership cannot be read.
class LooseSlot < ActiveRecord::Base
  belongs_to :loose_rack
  belongs_to :loose_item
end

class LooseItem < ActiveRecord::Base
  has_paper_trail
end

class LooseRack < ActiveRecord::Base
  has_many :loose_slots
  has_many :loose_items, through: :loose_slots
  has_paper_trail
end

RSpec.describe 'A has_many :through an unversioned join model' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [LooseSlot, LooseItem, LooseRack].each(&:delete_all)
  end

  let(:rack) do
    LooseRack.create!(name: 'Rack').tap do |rack|
      LooseSlot.create!(loose_rack: rack, loose_item: LooseItem.create!(name: 'Item'))
      rack.update!(name: 'Rack, filled')
    end
  end

  it 'refuses its history, naming the join model' do
    from, to = rack.versions.reorder(:created_at, :id).to_a

    expect { PaperTrailDiff.compare(from, to, associations: [:loose_items]) }
      .to raise_error(PaperTrailDiff::UnversionedAssociationError,
                      'association loose_items cannot be compared historically: it goes through ' \
                      'LooseSlot, which is not versioned. Add `has_paper_trail` to LooseSlot, or ' \
                      'mirror the fields you need onto a model that has it.')
  end

  it 'is an error diagnose reports' do
    from, to = rack.versions.reorder(:created_at, :id).to_a

    report = PaperTrailDiff.diagnose(from, to, associations: [:loose_items])

    expect(report).not_to be_ok
    expect(report.errors.map(&:code)).to include(:unversioned_through_model)
  end
end
