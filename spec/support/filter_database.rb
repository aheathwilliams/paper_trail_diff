# frozen_string_literal: true

require_relative 'database_connection'

# Its own version table and model, so it loads alongside either suite's schema.
# `versions.item_id` is an integer here, as PaperTrail's default migration makes
# it. `hidden` is never written to a version, and the default scope hides rows
# where it is set. FilterFeature shares the table through STI.
ActiveRecord::Schema.define do
  create_table :filter_versions, force: true do |table|
    table.string :item_type, null: false
    table.integer :item_id, null: false
    table.string :event, null: false
    table.string :whodunnit
    table.text :object
    table.text :object_changes
    table.integer :transaction_id
    table.datetime :created_at
  end

  create_table :filter_articles, force: true do |table|
    table.string :type
    table.string :title, null: false
    table.integer :views, null: false, default: 0
    table.integer :hidden, null: false, default: 0
    table.timestamps null: false
  end
end

class FilterVersion < ActiveRecord::Base
  include PaperTrail::VersionConcern
end

class FilterArticle < ActiveRecord::Base
  has_paper_trail versions: { class_name: 'FilterVersion' }, skip: [:hidden]
  default_scope { where(hidden: 0) }
end

class FilterFeature < FilterArticle; end
