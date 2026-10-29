# frozen_string_literal: true

require_relative 'association_database'

# A holder linked to authors through polymorphic links, read with
# `source_type:` so that a link to a tag is not one of its authors.
ActiveRecord::Schema.define do
  create_table :source_type_holders, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :source_type_authors, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :source_type_tags, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :source_type_links, force: true do |table|
    table.integer :holder_id
    table.string :target_type
    table.integer :target_id
    table.string :origin_type
    table.integer :origin_id
    table.timestamps null: false
  end
end

class SourceTypeAuthor < ActiveRecord::Base
  has_paper_trail
end

class SourceTypeTag < ActiveRecord::Base
  has_paper_trail
end

class SourceTypeLink < ActiveRecord::Base
  belongs_to :holder, class_name: 'SourceTypeHolder', optional: true
  belongs_to :target, polymorphic: true, optional: true
  # A second polymorphic key, which may name the same type as the target.
  belongs_to :origin, polymorphic: true, optional: true
  has_paper_trail
end

class SourceTypeHolder < ActiveRecord::Base
  has_many :links, class_name: 'SourceTypeLink', foreign_key: :holder_id
  has_many :linked_authors, through: :links, source: :target, source_type: 'SourceTypeAuthor'
  # Active Record also takes the type as a Symbol.
  has_many :symbol_authors, through: :links, source: :target, source_type: :SourceTypeAuthor
  has_paper_trail
end
