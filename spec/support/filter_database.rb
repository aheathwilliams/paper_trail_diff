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

  # PaperTrail writes a json object column as JSON types and does not cast
  # them back, so dates and times come back as strings.
  create_table :filter_json_versions, force: true do |table|
    table.string :item_type, null: false
    table.integer :item_id, null: false
    table.string :event, null: false
    table.string :whodunnit
    table.json :object
    table.json :object_changes
    table.integer :transaction_id
    table.datetime :created_at
  end

  create_table :filter_events, force: true do |table|
    table.integer :status, null: false, default: 0
    table.date :due_on
    table.datetime :starts_at
    table.json :details
    table.text :labels
    table.timestamps null: false
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

class FilterJsonVersion < ActiveRecord::Base
  include PaperTrail::VersionConcern
end

class FilterEvent < ActiveRecord::Base
  enum :status, { draft: 0, published: 1 }
  serialize :labels, coder: JSON
  has_paper_trail versions: { class_name: 'FilterVersion' }
end

class FilterJsonEvent < ActiveRecord::Base
  self.table_name = 'filter_events'
  has_paper_trail versions: { class_name: 'FilterJsonVersion' }
end
