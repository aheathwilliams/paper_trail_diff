# frozen_string_literal: true

# Recreates the association fixture's versions table with `json` object
# columns, as PostgreSQL apps often have them (`jsonb` behaves the same), and
# restores the text columns afterwards. PaperTrail stores such a column's
# values as JSON types: times and dates come back as strings it does not cast.
module JsonVersionsTable
  module_function

  def with_json_columns
    define(:json)
    yield
  ensure
    define(:text)
  end

  def define(type)
    ActiveRecord::Schema.define do
      create_table :versions, force: true do |table|
        table.string :item_type, null: false
        table.integer :item_id, null: false
        table.string :event, null: false
        table.string :whodunnit
        table.public_send(type, :object)
        table.public_send(type, :object_changes)
        table.integer :transaction_id
        table.datetime :created_at
      end
      add_index :versions, %i[item_type item_id]
      add_index :versions, :transaction_id
    end
    PaperTrail::Version.reset_column_information
  end
end
