# frozen_string_literal: true

require_relative 'association_database'

# PaperTrail's setup for UUID keys stores `versions.item_id` as a string, while
# the models in this history keep ordinary integer keys. A child id read from
# history is then "1" and the same child read from its live row is 1.
ActiveRecord::Schema.define do
  create_table :string_item_versions, force: true do |table|
    table.string :item_type, null: false
    table.string :item_id, null: false
    table.string :event, null: false
    table.string :whodunnit
    table.text :object
    table.text :object_changes
    table.integer :transaction_id
    table.datetime :created_at
  end

  create_table :string_item_version_associations, force: true do |table|
    table.integer :version_id
    table.string :foreign_key_name, null: false
    table.integer :foreign_key_id
    table.string :foreign_type
  end

  create_table :string_item_posts, force: true do |table|
    table.string :title, null: false
    table.timestamps null: false
  end

  create_table :string_item_notes, force: true do |table|
    table.integer :post_id, null: false
    table.string :body, null: false
    table.timestamps null: false
  end
end

class StringItemVersion < ActiveRecord::Base
  include PaperTrail::VersionConcern

  has_many :version_associations, class_name: 'StringItemVersionAssociation',
                                  foreign_key: :version_id, dependent: :destroy
  scope :within_transaction, ->(id) { where(transaction_id: id) }
end

class StringItemVersionAssociation < ActiveRecord::Base
  belongs_to :version, class_name: 'StringItemVersion'
end

STRING_ITEM_HISTORY = {
  versions: { class_name: 'StringItemVersion' },
  version_associations: { class_name: 'StringItemVersionAssociation' }
}.freeze

class StringItemPost < ActiveRecord::Base
  has_many :notes, class_name: 'StringItemNote', foreign_key: :post_id, inverse_of: :post
  has_paper_trail(**STRING_ITEM_HISTORY, synchronize_version_creation_timestamp: false)
end

class StringItemNote < ActiveRecord::Base
  belongs_to :post, class_name: 'StringItemPost', inverse_of: :notes
  has_paper_trail(**STRING_ITEM_HISTORY)
end
