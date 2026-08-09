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

  create_table :core_comments, force: true do |table|
    table.string :body, null: false
    table.integer :article_id, null: false
    table.timestamps null: false
  end

  create_table :documentation_articles, force: true do |table|
    table.string :title, null: false
    table.timestamps null: false
  end
end

class CoreArticle < ActiveRecord::Base
  has_many :comments, class_name: 'CoreComment', foreign_key: :article_id,
                      inverse_of: :article
  has_paper_trail
end

class CoreComment < ActiveRecord::Base
  belongs_to :article, class_name: 'CoreArticle', inverse_of: :comments
end

class DocumentationArticle < ActiveRecord::Base
  has_paper_trail
end
