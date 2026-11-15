# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :rtt_products, force: true do |table|
    table.string :type
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :rtt_orders, force: true do |table|
    table.string :title, null: false
    table.timestamps null: false
  end

  create_table :rtt_items, force: true do |table|
    table.integer :rtt_order_id
    table.integer :rtt_product_id
    table.integer :qty, null: false, default: 1
    table.timestamps null: false
  end
end

class RttProduct < ActiveRecord::Base
  has_paper_trail
end

class RttDigitalProduct < RttProduct
end

class RttOrder < ActiveRecord::Base
  has_many :items, class_name: 'RttItem'
  has_paper_trail
end

class RttItem < ActiveRecord::Base
  belongs_to :rtt_order, optional: true
  belongs_to :digital, class_name: 'RttDigitalProduct', foreign_key: :rtt_product_id, optional: true
  has_paper_trail
end

# Active Record reads a belongs_to that names an STI subclass only while the
# target's type names it, so retyping the target moves it in or out.
RSpec.describe 'A belongs_to target retyped in or out of its STI subclass' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [RttItem, RttOrder, RttProduct].each(&:delete_all)
  end

  let(:paths) { %w[items.digital] }

  def digital(snapshot)
    snapshot.associations.fetch('items').records.first.associations.fetch('digital').records
            .map { |record| [record.type, record.id] }
  end

  def steps(order, **options)
    PaperTrailDiff.analyze(order.reload, associations: paths, activity: true, snapshots: true,
                                         **options).activity_timeline
  end

  it 'moves the target out and back in at the updates that retype it' do
    product = RttDigitalProduct.create!(name: 'ebook')
    order = RttOrder.create!(title: 'o')
    item = RttItem.create!(rtt_order: order, rtt_product_id: product.id)
    started = Time.current
    RttProduct.find(product.id).update!(type: nil)
    item.update!(qty: 2)
    RttProduct.find(product.id).update!(type: 'RttDigitalProduct')

    read = steps(order, within: started..).map { |step| digital(step.to_snapshot) }
    expect(read).to eq([[], [], [['RttDigitalProduct', product.id]]])
  end
end
