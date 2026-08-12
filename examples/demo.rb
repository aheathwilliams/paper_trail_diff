# frozen_string_literal: true

# A complete, self-contained tour of paper_trail_diff. No Rails application, no
# migrations, nothing to clean up afterwards: it builds a throwaway SQLite
# database in memory, writes a small edit history, and prints what the gem can
# tell you about it.
#
#   ruby demo.rb
#
# Run it from anywhere. If the gems are not already installed it fetches them
# into a temporary bundle on first run, so the only requirement is Ruby 3.1+.

begin
  require 'active_record'
  require 'sqlite3'
  require 'paper_trail'
  require 'paper_trail-association_tracking'
  require 'paper_trail_diff'
rescue LoadError
  require 'bundler/inline'
  gemfile do
    source 'https://rubygems.org'
    gem 'activerecord', '~> 8.0'
    gem 'paper_trail', '>= 16', '< 18'
    gem 'paper_trail-association_tracking', '~> 2.3'
    gem 'paper_trail_diff'
    gem 'sqlite3', '>= 2.1'
  end
  require 'paper_trail_diff'
end

# ---------------------------------------------------------------- schema ----

PaperTrail.config.track_associations = true
PaperTrail::Version.include(PaperTrailAssociationTracking::VersionConcern)

ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
ActiveRecord::Migration.verbose = false
ActiveRecord.yaml_column_permitted_classes = [Symbol, Time]

ActiveRecord::Schema.define do
  create_table :versions, force: true do |t|
    t.string   :item_type, null: false
    t.string   :item_id, null: false
    t.string   :event, null: false
    t.string   :whodunnit
    t.text     :object
    t.text     :object_changes
    t.integer  :transaction_id
    t.datetime :created_at
  end
  add_index :versions, %i[item_type item_id]

  create_table :version_associations, force: true do |t|
    t.integer :version_id
    t.string  :foreign_key_name, null: false
    t.integer :foreign_key_id
    t.string  :foreign_type
  end
  add_index :version_associations, :version_id
  add_index :version_associations, %i[foreign_key_name foreign_key_id foreign_type],
            name: 'index_version_associations_on_foreign_key'

  create_table(:articles, force: true) do |t|
    t.string :title, null: false
    t.timestamps
  end
  create_table :comments, force: true do |t|
    t.string  :body, null: false
    t.integer :article_id, null: false
    t.timestamps
  end
end

class Article < ActiveRecord::Base
  has_many :comments, dependent: :destroy, inverse_of: :article
  has_paper_trail synchronize_version_creation_timestamp: false
end

class Comment < ActiveRecord::Base
  belongs_to :article, inverse_of: :comments
  has_paper_trail
end

# --------------------------------------------------------------- history ----

def as(person, &) = PaperTrail.request(whodunnit: person, &)

article = as('Maya') { Article.create!(title: 'Apollo Notes') }
as('Maya') { article.update!(title: 'Apollo Notes — Draft') }
comment = as('Jon') { article.comments.create!(body: 'Needs a launch date.') }
as('system') { article.update!(title: 'Apollo Notes — Draft (auto-tagged)') }
as('Priya') { comment.update!(body: 'Needs a launch date and a source.') }
as('Maya') { article.update!(title: 'Apollo Notes — Final') }

versions = article.versions.reload.order(:created_at, :id).to_a
puts "Wrote #{PaperTrail::Version.count} versions for 1 article and 1 comment.\n\n"

def section(title)
  puts "#{title}\n#{'-' * title.length}"
  yield
  puts
end

# ----------------------------------------------------------------- tour -----

# The first version records the state before the article existed, so start from
# the one after it to compare two real states.
early = versions.fetch(1)

section 'What changed between an early draft and now?' do
  diff = PaperTrailDiff.compare(early, article, associations: [:comments])
  diff.attributes.each do |name, change|
    puts "  #{name}: #{change.from.inspect} -> #{change.to.inspect}"
  end
  (diff.associations['comments']&.added || []).each do |record|
    puts "  comment added: #{record.attributes['body'].inspect}"
  end
end

section 'Every checkpoint in order' do
  PaperTrailDiff.timeline(article, from: :first, to: :last).reject(&:empty?).each do |step|
    who = step.from_boundary.whodunnit.to_s.ljust(7)
    change = step.diff.attributes['title']
    if change
      puts "  #{who} title: #{change.from.inspect} -> #{change.to.inspect}"
    else
      # A version records the state before its own event, so the first step is
      # the article coming into existence rather than an edit to it.
      puts "  #{who} created the article"
    end
  end
end

section 'Who changed what, including nested records' do
  steps = PaperTrailDiff.activity_timeline(
    article, from: :first, to: article, associations: [:comments]
  )
  steps.reject(&:empty?).each do |step|
    subject = step.from_boundary.item_type
    detail = step.diff.attributes.keys + step.diff.associations.keys
    puts "  #{step.from_boundary.whodunnit.to_s.ljust(7)} changed #{subject} #{detail.inspect}"
  end
end

section "Just one person's work" do
  steps = PaperTrailDiff.activity_timeline(
    article, from: :first, to: article, associations: [:comments]
  )
  by_jon = steps.reject(&:empty?).select { |step| step.from_boundary.whodunnit == 'Jon' }
  puts "  Jon made #{by_jon.length} change(s), including to records that are not the article:"
  by_jon.each do |step|
    puts "    #{step.from_boundary.item_type}: #{step.diff.to_h[:associations].keys.inspect}"
  end
end

puts 'Full documentation: https://github.com/aheathwilliams/paper_trail_diff'
