# frozen_string_literal: true

require_relative 'association_database'

# Models whose versions are kept in a table other than PaperTrail's, alone or
# alongside models that keep theirs in the default one.
ActiveRecord::Schema.define do
  create_table :shelf_versions, force: true do |table|
    table.string :item_type, null: false
    table.integer :item_id, null: false
    table.string :event, null: false
    table.string :whodunnit
    table.text :object
    table.text :object_changes
    table.integer :transaction_id
    table.datetime :created_at, precision: 6
  end

  create_table :shelf_notes, force: true do |table|
    table.integer :book_id
    table.string :body, null: false
  end

  create_table :shelf_labels, force: true do |table|
    table.string :name, null: false
  end

  create_table :default_shelves_shelf_labels, id: false, force: true do |table|
    table.integer :split_shelf_id
    table.integer :shelf_label_id
  end

  %i[shelves shelf_books default_shelves default_shelf_books].each do |name|
    create_table name, force: true do |table|
      table.integer :shelf_id
      table.string :title, null: false
      table.timestamps null: false
    end
  end
end

class ShelfVersion < PaperTrail::Version
  self.table_name = 'shelf_versions'
end

# One version table for a root and its association, other than PaperTrail's.
class Shelf < ActiveRecord::Base
  has_many :books, class_name: 'ShelfBook', foreign_key: :shelf_id, inverse_of: :shelf
  has_paper_trail versions: { class_name: 'ShelfVersion' }
end

class ShelfBook < ActiveRecord::Base
  belongs_to :shelf, optional: true, inverse_of: :books
  has_paper_trail versions: { class_name: 'ShelfVersion' }
end

# The same models with PaperTrail's table, to read the same history from.
class DefaultShelf < ActiveRecord::Base
  has_many :books, class_name: 'DefaultShelfBook', foreign_key: :shelf_id, inverse_of: :shelf
  has_paper_trail
end

class DefaultShelfBook < ActiveRecord::Base
  belongs_to :shelf, class_name: 'DefaultShelf', optional: true, inverse_of: :books
  has_paper_trail
end

# Root versions in the default table, a child's in another.
class SplitShelf < ActiveRecord::Base
  self.table_name = 'default_shelves'
  has_many :books, class_name: 'SplitShelfBook', foreign_key: :shelf_id, inverse_of: :shelf
  has_paper_trail
end

class SplitShelfBook < ActiveRecord::Base
  self.table_name = 'shelf_books'
  belongs_to :shelf, class_name: 'SplitShelf', optional: true, inverse_of: :books
  has_paper_trail versions: { class_name: 'ShelfVersion' }
end

class ShelfNote < ActiveRecord::Base
  belongs_to :book, class_name: 'SplitShelfBook', optional: true
  has_paper_trail versions: { class_name: 'ShelfVersion' }
end

class ShelfLabel < ActiveRecord::Base
  has_paper_trail versions: { class_name: 'ShelfVersion' }
end

# Unversioned ends, which have no history to compare.
class LooseShelf < ActiveRecord::Base
  self.table_name = 'shelves'
  has_many :books, class_name: 'ShelfBook', foreign_key: :shelf_id
end

class LooseShelfBook < ActiveRecord::Base
  self.table_name = 'shelf_books'
  belongs_to :shelf, class_name: 'LooseShelf', optional: true
  belongs_to :holder, polymorphic: true, optional: true
  has_paper_trail versions: { class_name: 'ShelfVersion' }
end

class SplitShelf
  has_many :notes, through: :books
  has_and_belongs_to_many :labels, class_name: 'ShelfLabel',
                                   join_table: 'default_shelves_shelf_labels',
                                   association_foreign_key: :shelf_label_id
end

class SplitShelfBook
  has_many :notes, class_name: 'ShelfNote', foreign_key: :book_id
end

class ShelfBook
  belongs_to :default_shelf, class_name: 'DefaultShelf', foreign_key: :shelf_id, optional: true
end

class Shelf
  has_many :default_shelves, through: :books, source: :default_shelf
  has_many :notes, through: :books, source: :shelf
end
