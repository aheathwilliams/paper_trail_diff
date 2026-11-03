# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :alarm_rooms, force: true do |table|
    table.string :name, null: false
  end

  create_table :alarm_bells, force: true do |table|
    table.integer :room_id, null: false
    table.string :label, null: false
    table.time :rings_at
  end
end

class AlarmBell < ActiveRecord::Base
  belongs_to :room, class_name: 'AlarmRoom'
  has_paper_trail
end

# A scope written as SQL cannot be read from stored attributes, so this path
# is read with PT-AT, which rebuilds each bell with PaperTrail's reify.
class AlarmRoom < ActiveRecord::Base
  has_many :labelled_bells, -> { where("label <> ''") }, class_name: 'AlarmBell',
                                                         foreign_key: :room_id
  has_paper_trail
end

RSpec.describe 'History of a time of day on an association read with PT-AT' do
  # SQL Server's adapter stores a time as its own type instead.
  def time_classes
    classes = [ActiveRecord::Type::Time::Value]
    return classes unless ActiveRecord::Base.connection.adapter_name == 'SQLServer'

    classes + [ActiveRecord::ConnectionAdapters::SQLServer::Type::Time]
  end

  around do |example|
    permitted = ActiveRecord.yaml_column_permitted_classes
    ActiveRecord.yaml_column_permitted_classes = permitted + time_classes
    example.run
  ensure
    ActiveRecord.yaml_column_permitted_classes = permitted
  end

  # PT-AT rebuilds a member only from a version saved after the endpoint.
  it 'reads the time each member recorded' do
    room = AlarmRoom.create!(name: 'Kitchen')
    bell = AlarmBell.create!(room_id: room.id, label: 'Wake', rings_at: '07:30')
    room.update!(name: 'Bedroom')
    renamed = room.versions.reorder(:created_at, :id).last
    bell.update!(label: 'Rise')

    diff = PaperTrailDiff.compare(renamed, room.reload, associations: [:labelled_bells],
                                                        allow_approximate: true)

    expect(diff.attributes.keys).to eq(['name'])
    changed = diff.associations.fetch('labelled_bells').to_h.fetch(:changed)
    expect(changed.map { |change| change[:attributes].keys }).to eq([['label']])
  end
end
