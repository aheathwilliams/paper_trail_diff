# frozen_string_literal: true

require 'active_record'
require 'paper_trail'
require 'paper_trail_diff'
# Versions are ordered by created_at, stamped from Time.now. A host clock that
# steps backwards, as WSL2's does, could date a destroy before the update it
# follows; the specs' clock keeps every reading in this process increasing.
require_relative '../../spec/support/monotonic_clock'
require_relative 'association_window'

module ReportingBenchmark
  # Seeds genuine PaperTrail history in a process-local database, never an app database.
  class Workload
    include AssociationWindow

    CASES = %w[many_roots retained_activity long_history limit_refusal deleted_roots
               association_window].freeze

    attr_reader :name, :size

    def initialize(name, size)
      raise ArgumentError, 'unknown scenario' unless CASES.include?(name)
      raise ArgumentError, 'size must be positive' unless size.positive?

      @name = name
      @size = size
    end

    def prepare
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      ActiveRecord::Schema.verbose = false
      return prepare_association_window if name == 'association_window'

      create_schema
      Object.const_set(:BenchmarkArticle, Class.new(ActiveRecord::Base))
      BenchmarkArticle.has_paper_trail
      root_count.times { |index| seed_root(index) }
    end

    def call
      return report_association_window if name == 'association_window'

      PaperTrailDiff.analyze_scope(BenchmarkArticle, **options)
    end

    def root_count
      name == 'long_history' ? 1 : size
    end

    def updates_per_root
      name == 'long_history' ? size : 5
    end

    def expected_roots
      name == 'deleted_roots' ? 0 : root_count
    end

    def limit
      return root_count if name == 'deleted_roots'

      name == 'limit_refusal' ? 5 : [expected_roots, 1].max
    end

    private

    def create_schema
      ActiveRecord::Schema.define do
        create_table(:benchmark_articles) do |table|
          table.string :title
          table.string :status
          table.text :body
        end
        create_table(:versions) do |table|
          table.string :item_type, :event, :whodunnit
          table.string :item_id
          table.text :object, :object_changes
          table.datetime :created_at
        end
        add_index :versions, %i[item_type item_id]
      end
    end

    def seed_root(index)
      root = BenchmarkArticle.create!(title: "Article #{index}", status: 'draft', body: 'x' * 1024)
      updates_per_root.times { |update| root.update!(title: "Article #{index} v#{update}") }
      root.destroy! if name == 'deleted_roots'
    end

    def options
      result = { within: Time.at(0).utc..(Time.now.utc + 60), limit: limit }
      if name == 'retained_activity'
        result[:activity] = true
        result[:snapshots] = true
      end
      if name == 'deleted_roots'
        result.merge!(activity: true, snapshots: true,
                      include_deleted: true)
      end
      result
    end
  end
end
