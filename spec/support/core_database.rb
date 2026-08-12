# frozen_string_literal: true

require 'active_record'
require 'securerandom'
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

  # A version table with a non-sequential primary key, as a UUID column is.
  # Doubles as coverage for `has_paper_trail versions: { class_name: }`.
  create_table :uuid_versions, id: false, force: true do |table|
    table.string :id, primary_key: true
    table.string :item_type, null: false
    table.string :item_id, null: false
    table.string :event, null: false
    table.string :whodunnit
    table.text :object
    table.text :object_changes
    table.datetime :created_at
  end

  add_index :uuid_versions, %i[item_type item_id]

  create_table :uuid_keyed_articles, force: true do |table|
    table.string :title, null: false
    table.timestamps null: false
  end

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

# Records its history in a table whose primary key is a UUID, so versions
# sharing a timestamp cannot be ordered by id the way autoincrement ones can.
class UuidVersion < ActiveRecord::Base
  include PaperTrail::VersionConcern

  before_create { self.id ||= SecureRandom.uuid }
end

class UuidKeyedArticle < ActiveRecord::Base
  has_paper_trail versions: { class_name: 'UuidVersion' }
end
