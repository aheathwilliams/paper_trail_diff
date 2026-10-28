# frozen_string_literal: true

require_relative 'database_connection'

# Its own tables, so it loads alongside either suite's schema. A post belongs
# to an author, has comments and one cover, and never versions `views`. A
# comment's subject is polymorphic, and comments nest through `parent_id`; a
# cover is attached polymorphically. A tag's key is its post and name.
ActiveRecord::Schema.define do
  create_table :norm_versions, force: true do |table|
    table.string :item_type, null: false
    table.integer :item_id, null: false
    table.string :event, null: false
    table.string :whodunnit
    table.text :object
    table.text :object_changes
    table.integer :transaction_id
    table.datetime :created_at, precision: 6
  end

  create_table :norm_authors, force: true do |table|
    table.string :name
  end

  create_table :norm_posts, force: true do |table|
    table.string :title
    table.integer :views, null: false, default: 0
    table.string :secret
    table.integer :author_id
    table.datetime :published_at, precision: 6
  end

  create_table :norm_comments, force: true do |table|
    table.string :type
    table.string :body
    table.integer :post_id
    table.string :subject_type
    table.integer :subject_id
    table.integer :parent_id
  end

  create_table :norm_tags, primary_key: %i[post_id name], force: true do |table|
    table.integer :post_id
    table.string :name
    table.string :colour
  end

  create_table :norm_covers, force: true do |table|
    table.string :caption
    table.string :owner_type
    table.integer :owner_id
  end
end

class NormVersion < ActiveRecord::Base
  include PaperTrail::VersionConcern
end

class NormAuthor < ActiveRecord::Base; end

class NormPost < ActiveRecord::Base
  has_paper_trail versions: { class_name: 'NormVersion' }, skip: [:views, { secret: nil }]
  belongs_to :author, class_name: 'NormAuthor', optional: true
  has_many :comments, -> { order(:id) }, class_name: 'NormComment', foreign_key: :post_id,
                                         inverse_of: :post
  has_one :cover, class_name: 'NormCover', as: :owner
end

class NormComment < ActiveRecord::Base
  belongs_to :post, class_name: 'NormPost', optional: true, inverse_of: :comments
  belongs_to :subject, polymorphic: true, optional: true
  belongs_to :parent, class_name: 'NormComment', optional: true
  has_many :replies, class_name: 'NormComment', foreign_key: :parent_id
end

# An STI child whose `post` reads a different column than its parent's.
class NormReply < NormComment
  belongs_to :post, class_name: 'NormPost', foreign_key: :subject_id, optional: true
end

class NormCover < ActiveRecord::Base
  belongs_to :owner, polymorphic: true, optional: true
end

class NormTag < ActiveRecord::Base; end
