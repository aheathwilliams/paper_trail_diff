# frozen_string_literal: true

module ReportingBenchmark
  # The association_window scenario: a `report` since a window's start over
  # articles with comments, read through PT-AT, with the README's indexes in
  # place. Each article was created with two comments in one transaction
  # before the window, then edited with one of them in another inside it, so
  # every statement that looks for a transaction crossing the start has the
  # window's comment versions to read. A plan that reads them again for each
  # article's version grows with the square of the articles.
  module AssociationWindow
    COMMENTS = 2

    private

    def prepare_association_window
      require 'paper_trail-association_tracking'
      PaperTrail.config.track_associations = true
      PaperTrail::Version.include(PaperTrailAssociationTracking::VersionConcern)
      create_association_schema
      define_association_models
      articles = Array.new(size) { |index| create_article(index) }
      @start = Time.now.utc
      articles.each { |article| edit_article(article) }
    end

    def report_association_window
      PaperTrailDiff.report(BenchmarkArticle.all, since: @start, limit: limit,
                                                  associations: [:comments])
    end

    def create_article(index)
      BenchmarkArticle.transaction do
        article = BenchmarkArticle.create!(title: "Article #{index}", status: 'draft',
                                           body: 'x' * 1024)
        COMMENTS.times { |comment| article.comments.create!(body: "Comment #{comment}") }
        article
      end
    end

    def edit_article(article)
      BenchmarkArticle.transaction do
        article.update!(title: "#{article.title}!")
        article.comments.first.update!(body: 'Edited')
      end
    end

    def define_association_models
      Object.const_set(:BenchmarkArticle, Class.new(ActiveRecord::Base))
      Object.const_set(:BenchmarkComment, Class.new(ActiveRecord::Base))
      BenchmarkArticle.has_many :comments, class_name: 'BenchmarkComment', foreign_key: :article_id,
                                           inverse_of: :article
      BenchmarkComment.belongs_to :article, class_name: 'BenchmarkArticle', inverse_of: :comments
      [BenchmarkArticle, BenchmarkComment].each(&:has_paper_trail)
    end

    def create_association_schema
      ActiveRecord::Schema.define do
        create_table(:benchmark_articles) do |table|
          table.string :title, :status
          table.text :body
        end
        create_table(:benchmark_comments) do |table|
          table.references :article
          table.string :body
        end
      end
      create_versions_table
      create_version_associations_table
    end

    # PaperTrail's table with PT-AT's column, and the indexes the README asks for.
    def create_versions_table
      ActiveRecord::Schema.define do
        create_table(:versions) do |table|
          table.string :item_type, :event, :whodunnit
          table.integer :item_id, :transaction_id
          table.text :object, :object_changes
          table.datetime :created_at
        end
        add_index :versions, :transaction_id
        add_index :versions, %i[item_type item_id created_at id],
                  name: 'index_versions_on_item_and_timeline'
        add_index :versions, %i[item_type created_at item_id],
                  name: 'index_versions_on_type_and_time'
      end
    end

    def create_version_associations_table
      ActiveRecord::Schema.define do
        create_table(:version_associations) do |table|
          table.integer :version_id, :foreign_key_id
          table.string :foreign_key_name, :foreign_type
        end
        add_index :version_associations, :version_id
        add_index :version_associations, %i[foreign_key_name foreign_key_id foreign_type],
                  name: 'index_version_associations_on_foreign_key'
      end
    end
  end
end
