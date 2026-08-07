# frozen_string_literal: true

require 'active_record'
require 'sqlite3'

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Migration.verbose = false
ActiveRecord.yaml_column_permitted_classes = [Symbol, Time]

ActiveRecord::Schema.define do
  create_table :versions, force: true do |table|
    table.string :item_type, null: false
    table.string :item_id, null: false
    table.string :event, null: false
    table.string :whodunnit
    table.text :object
    table.text :object_changes
    table.datetime :created_at
  end

  add_index :versions, %i[item_type item_id]

  create_table :core_articles, force: true do |table|
    table.string :title, null: false
    table.string :internal_note, null: false
    table.timestamps null: false
  end
end

class CoreArticle < ActiveRecord::Base
  has_paper_trail
end
