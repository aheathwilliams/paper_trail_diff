# frozen_string_literal: true

require_relative '../support/core_database'

# Both ends versioned and PT-AT not loaded, as in an application that uses
# PaperTrail alone.
ActiveRecord::Schema.define do
  create_table :untracked_shelves, force: true do |table|
    table.string :name, null: false
  end

  create_table :untracked_books, force: true do |table|
    table.string :title, null: false
    table.integer :shelf_id, null: false
  end
end

class UntrackedBook < ActiveRecord::Base
  belongs_to :shelf, class_name: 'UntrackedShelf'
  has_paper_trail
end

class UntrackedShelf < ActiveRecord::Base
  has_many :books, class_name: 'UntrackedBook', foreign_key: :shelf_id, inverse_of: :shelf
  has_paper_trail
end

RSpec.describe 'Associations between versioned models without PT-AT' do
  let(:shelf) { UntrackedShelf.create!(name: 'Fiction') }

  before do
    skip 'PT-AT is loaded in this process' if defined?(PaperTrailAssociationTracking)
    UntrackedBook.create!(title: 'Dune', shelf: shelf)
  end

  it 'refuses history with the tracking error' do
    expect { PaperTrailDiff.compare(shelf.versions.first, shelf, associations: [:books]) }
      .to raise_error(PaperTrailDiff::AssociationTrackingUnavailableError,
                      /must be loaded and enabled/)
  end

  it 'still compares two current records' do
    expect(PaperTrailDiff.compare(shelf, shelf, associations: [:books])).to be_empty
  end

  it 'still discovers association paths' do
    expect(PaperTrailDiff.association_paths(UntrackedShelf).map(&:path)).to include('books')
  end
end
