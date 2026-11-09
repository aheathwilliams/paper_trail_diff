# frozen_string_literal: true

require_relative 'association_database'

# Models whose version table keeps `created_at` to the second, as a MySQL
# `datetime` column made before Rails 7 does.
ActiveRecord::Schema.define do
  create_table :coarse_versions, force: true do |table|
    table.string :item_type, null: false
    table.integer :item_id, null: false
    table.string :event, null: false
    table.string :whodunnit
    table.text :object
    table.text :object_changes
    table.integer :transaction_id
    table.datetime :created_at, precision: 0
  end

  create_table :coarse_folders, force: true do |table|
    table.string :title, null: false
  end

  create_table :coarse_pages, force: true do |table|
    table.integer :folder_id
    table.string :body, null: false
  end
end

class CoarseVersion < PaperTrail::Version
  self.table_name = 'coarse_versions'
end

class CoarseFolder < ActiveRecord::Base
  has_many :pages, class_name: 'CoarsePage', foreign_key: :folder_id, inverse_of: :folder
  has_paper_trail versions: { class_name: 'CoarseVersion' }
end

class CoarsePage < ActiveRecord::Base
  belongs_to :folder, class_name: 'CoarseFolder', optional: true, inverse_of: :pages
  has_paper_trail versions: { class_name: 'CoarseVersion' }
end
