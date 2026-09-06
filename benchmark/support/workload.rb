# frozen_string_literal: true

require 'active_record'
require 'paper_trail'
require 'paper_trail_diff'

module ReportingBenchmark
  # Seeds genuine PaperTrail history in a process-local database, never an app database.
  class Workload
    CASES = %w[many_roots retained_activity long_history sparse_matches no_matches
               limit_refusal].freeze

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
      create_schema
      Object.const_set(:BenchmarkArticle, Class.new(ActiveRecord::Base))
      BenchmarkArticle.has_paper_trail
      root_count.times { |index| seed_root(index) }
    end

    def call
      PaperTrailDiff.analyze_scope(BenchmarkArticle, **options)
    end

    def root_count
      name == 'long_history' ? 1 : size
    end

    def updates_per_root
      name == 'long_history' ? size : 5
    end

    def expected_roots
      return 0 if name == 'no_matches'
      return (size + 99) / 100 if name == 'sparse_matches'

      root_count
    end

    def limit
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
      status = name == 'sparse_matches' && (index % 100).zero? ? 'review' : 'draft'
      root = BenchmarkArticle.create!(title: "Article #{index}", status: status, body: 'x' * 1024)
      updates_per_root.times { |update| root.update!(title: "Article #{index} v#{update}") }
    end

    def options
      result = { within: Time.at(0).utc..(Time.now.utc + 60), limit: limit, close_on: :current }
      result.merge!(activity: true, snapshots: true) if name == 'retained_activity'
      result[:historical_filter] = predicate if predicate
      result
    end

    def predicate
      return ->(_state) { true } if name == 'limit_refusal'
      return unless %w[sparse_matches no_matches].include?(name)

      ->(state) { state.status == 'review' }
    end
  end
end
