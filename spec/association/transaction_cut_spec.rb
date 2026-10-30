# frozen_string_literal: true

require_relative '../support/string_item_database'

# PaperTrail's setup for UUID keys stores item_id as a string. SQLite compares
# 5 with '5', where PostgreSQL refuses to, so the SQL itself is checked.
RSpec.describe PaperTrailDiff::TransactionCut do
  it 'compares the root id as the version table stores it' do
    post = StringItemPost.create!(title: 'Post')
    sql = []
    connection = StringItemVersion.connection
    allow(connection).to receive(:select_rows).and_wrap_original do |original, query, *rest|
      sql << query
      original.call(query, *rest)
    end

    now = Time.now.utc
    described_class.windows(StringItemPost, [post], PaperTrailDiff::TimeRange.new(now..now))

    expect(sql.first).to include("= #{StringItemVersion.connection.quote(post.id.to_s)}")
  end
end
