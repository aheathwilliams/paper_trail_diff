# frozen_string_literal: true

require_relative 'database_connection'

# Its own tables, so it loads alongside either suite's schema. Both note models
# share one table; only RecordedNote's version table has `object_changes`.
# `stage` is an enum, so PaperTrail stores its integer, which only the model's
# attribute type turns back into a label. A tag's key is its note and name;
# PaperTrail cannot write a version for it, so specs write one by hand.
ActiveRecord::Schema.define do
  %i[recorded_versions unrecorded_versions].each do |name|
    create_table name, force: true do |table|
      table.string :item_type, null: false
      table.integer :item_id, null: false
      table.string :event, null: false
      table.string :whodunnit
      table.text :object
      table.text :object_changes if name == :recorded_versions
      table.datetime :created_at
    end
  end

  create_table :recorded_notes, force: true do |table|
    table.string :title
    table.integer :rank
    table.integer :stage
    table.timestamps null: false
  end

  create_table :recorded_pubs, force: true do |table|
    table.string :type
    table.integer :state, default: 0
    table.string :code
  end

  create_table :recorded_tags, primary_key: %i[note_id name], force: true do |table|
    table.integer :note_id
    table.string :name
    table.string :colour
  end
end

class RecordedVersion < ActiveRecord::Base
  include PaperTrail::VersionConcern
end

class UnrecordedVersion < ActiveRecord::Base
  include PaperTrail::VersionConcern
end

class RecordedNote < ActiveRecord::Base
  enum :stage, { draft: 0, published: 1 }
  has_paper_trail versions: { class_name: 'RecordedVersion' }
end

class UnrecordedNote < ActiveRecord::Base
  self.table_name = 'recorded_notes'
  has_paper_trail versions: { class_name: 'UnrecordedVersion' }
end

# PaperTrail stores `rank` with every version but records no changes to it.
class RankIgnoringNote < ActiveRecord::Base
  self.table_name = 'recorded_notes'
  has_paper_trail versions: { class_name: 'RecordedVersion' }, ignore: [:rank]
end

# Only the subclass types its columns, and the version table keeps no
# `item_subtype`, so a version names the base class.
class RecordedPub < ActiveRecord::Base
  has_paper_trail versions: { class_name: 'RecordedVersion' }
end

class RecordedBook < RecordedPub
  enum :state, { draft: 0, printed: 1 }
  attribute :code, :integer
end

class RecordedTag < ActiveRecord::Base
  has_paper_trail versions: { class_name: 'RecordedVersion' }
end
