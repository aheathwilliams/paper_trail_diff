# frozen_string_literal: true

require 'active_record'
require 'sqlite3'
require 'paper_trail-association_tracking'

PaperTrail.config.track_associations = true
PaperTrail::Version.include(PaperTrailAssociationTracking::VersionConcern)

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Migration.verbose = false
ActiveRecord.yaml_column_permitted_classes = [Symbol, Time]

ActiveRecord::Schema.define do
  create_table :versions, force: true do |table|
    table.string :item_type, null: false
    table.integer :item_id, null: false
    table.string :event, null: false
    table.string :whodunnit
    table.text :object
    table.text :object_changes
    table.integer :transaction_id
    table.datetime :created_at
  end

  add_index :versions, %i[item_type item_id]
  add_index :versions, :transaction_id

  create_table :version_associations, force: true do |table|
    table.integer :version_id
    table.string :foreign_key_name, null: false
    table.integer :foreign_key_id
    table.string :foreign_type
  end

  add_index :version_associations, :version_id
  add_index :version_associations,
            %i[foreign_key_name foreign_key_id foreign_type],
            name: 'index_version_associations_on_foreign_key'

  create_table :tracked_authors, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :tracked_articles, force: true do |table|
    table.string :title, null: false
    table.integer :author_id
    table.timestamps null: false
  end

  create_table :tracked_profiles, force: true do |table|
    table.string :bio, null: false
    table.integer :article_id, null: false
    table.timestamps null: false
  end

  create_table :tracked_comments, force: true do |table|
    table.string :body, null: false
    table.integer :article_id, null: false
    table.timestamps null: false
  end

  create_table :tracked_replies, force: true do |table|
    table.string :body, null: false
    table.integer :comment_id, null: false
    table.timestamps null: false
  end

  create_table :tracked_tags, force: true do |table|
    table.string :name, null: false
    table.timestamps null: false
  end

  create_table :tracked_articles_tags, id: false, force: true do |table|
    table.integer :tracked_article_id, null: false
    table.integer :tracked_tag_id, null: false
  end
end

class TrackedAuthor < ActiveRecord::Base
  has_many :articles, class_name: 'TrackedArticle', foreign_key: :author_id,
                      inverse_of: :author
  has_paper_trail
end

class TrackedArticle < ActiveRecord::Base
  belongs_to :author, class_name: 'TrackedAuthor', optional: true, inverse_of: :articles
  has_one :profile, class_name: 'TrackedProfile', foreign_key: :article_id,
                    inverse_of: :article
  has_many :comments, class_name: 'TrackedComment', foreign_key: :article_id,
                      inverse_of: :article
  has_and_belongs_to_many :tags,
                          class_name: 'TrackedTag',
                          join_table: :tracked_articles_tags,
                          foreign_key: :tracked_article_id,
                          association_foreign_key: :tracked_tag_id
  has_paper_trail synchronize_version_creation_timestamp: false
end

class TrackedProfile < ActiveRecord::Base
  belongs_to :article, class_name: 'TrackedArticle', inverse_of: :profile
  has_paper_trail
end

class TrackedComment < ActiveRecord::Base
  belongs_to :article, class_name: 'TrackedArticle', inverse_of: :comments
  has_many :replies, class_name: 'TrackedReply', foreign_key: :comment_id,
                     inverse_of: :comment
  has_paper_trail
end

class TrackedReply < ActiveRecord::Base
  belongs_to :comment, class_name: 'TrackedComment', inverse_of: :replies
  has_paper_trail
end

class TrackedTag < ActiveRecord::Base
  has_and_belongs_to_many :articles,
                          class_name: 'TrackedArticle',
                          join_table: :tracked_articles_tags,
                          foreign_key: :tracked_tag_id,
                          association_foreign_key: :tracked_article_id
  has_paper_trail
end
