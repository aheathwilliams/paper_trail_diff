# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::TotalOrder do
  describe '.apply' do
    # The relation's order, with identifiers in double quotes whatever the
    # adapter quotes them with.
    def order_of(relation)
      quote = ActiveRecord::Base.connection.quote_column_name('x')
      sql = described_class.apply(relation).to_sql
      sql[/ORDER BY (.*)\z/, 1].tr("#{quote[0]}#{quote[-1]}", '""')
    end

    def quoted(table, column)
      connection = ActiveRecord::Base.connection
      "#{connection.quote_table_name(table)}.#{connection.quote_column_name(column)}"
    end

    it 'sorts by the key after an order that does not' do
      key = '"filter_articles"."id" ASC'

      expect(order_of(FilterArticle.all)).to eq(key)
      expect(order_of(FilterArticle.order(title: :desc)))
        .to eq(%("filter_articles"."title" DESC, #{key}))
      # A column whose name holds the key's.
      expect(order_of(FilterArticle.order('title DESC, hidden')))
        .to eq("title DESC, hidden, #{key}")
      expect(order_of(FilterArticle.order(FilterEvent.arel_table[:id])))
        .to eq(%("filter_events"."id", #{key}))
      expect(order_of(FilterArticle.order('filter_events.id DESC')))
        .to eq("filter_events.id DESC, #{key}")
    end

    # SQL Server rejects a column listed twice in an order, in any spelling.
    it 'keeps an order that sorts by the key' do
      key = '"filter_articles"."id"'

      expect(order_of(FilterArticle.order(id: :desc))).to eq("#{key} DESC")
      expect(order_of(FilterArticle.order(:title, :id)))
        .to eq(%("filter_articles"."title" ASC, #{key} ASC))
      expect(order_of(FilterArticle.order(FilterArticle.arel_table[:id]))).to eq(key)
      expect(order_of(FilterArticle.order(Arel.sql('id').desc))).to eq('id DESC')
      expect(order_of(FilterArticle.order('ID DESC'))).to eq('ID DESC')
      expect(order_of(FilterArticle.order(Arel.sql('title, FILTER_ARTICLES.id'))))
        .to eq('title, FILTER_ARTICLES.id')
      expect(order_of(FilterArticle.order(Arel.sql("#{quoted('filter_articles', 'id')} DESC"))))
        .to eq("#{key} DESC")
    end

    # A database sorts groups only by what they group or aggregate.
    it 'keeps the order of a relation grouped by anything but the key' do
      latest = FilterArticle.select('MAX(id) AS id')
      key = '"filter_articles"."id" ASC'

      expect(order_of(latest.group(:title).order(:title))).to eq('"filter_articles"."title" ASC')
      expect(order_of(latest.group(:title).order(Arel.sql('MAX(id) DESC')))).to eq('MAX(id) DESC')
      # Without an order of its own it would be sorted by the key, which a
      # database rejects, so it is refused before any query.
      expect { described_class.apply(latest.group(:title)) }
        .to raise_error(PaperTrailDiff::ConfigurationError, /needs an order of its own/)
      [:id, 'filter_articles.id', FilterArticle.arel_table[:id]].each do |group|
        expect(order_of(FilterArticle.group(group, :title).order(:title)))
          .to eq(%("filter_articles"."title" ASC, #{key}))
      end
    end
  end
end
