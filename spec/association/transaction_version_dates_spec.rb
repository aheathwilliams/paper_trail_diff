# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :dated_posts, force: true do |table|
    table.string :title, null: false
    table.integer :edits, default: 0, null: false
    table.timestamps null: false
  end

  create_table :dated_lines, force: true do |table|
    table.string :body, null: false
    table.integer :dated_post_id
    table.timestamps null: false
  end
end

class DatedPost < ActiveRecord::Base
  has_many :lines, class_name: 'DatedLine'
  has_paper_trail
end

# The callback comes before has_paper_trail, so the post's version is saved
# first, and the line's last, dated as its save began.
class DatedLine < ActiveRecord::Base
  belongs_to :dated_post, optional: true
  after_update { dated_post.update!(edits: dated_post.edits + 1) }
  has_paper_trail
end

# A transaction takes effect at its latest dated version, as windows compare
# versions by date, whichever version it saved last.
RSpec.describe 'A transaction whose versions are dated out of the order they were saved in' do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [DatedLine, DatedPost].each(&:delete_all)
  end

  def rows(post, window)
    SpecTimelines.activity_timeline(post, within: window, associations: [:lines])
                 .flat_map(&:change_rows).select { |row| row.change == :changed }
                 .map { |row| [row.record&.type, row.attribute] }
  end

  # With more than one version table, a transaction's first version marks
  # where it began, so its dates must keep their order there (see
  # TransactionAnchors). Other specs load more tables.
  it 'reports each change in one of two windows cut between its dates' do
    allow(PaperTrailDiff::TransactionAnchors).to receive(:version_classes)
      .and_return([PaperTrail::Version])
    post = DatedPost.create!(title: 'p')
    line = post.lines.create!(body: 'l')
    start = Time.now.utc
    line.update!(body: 'l2')
    versions = PaperTrail::Version.where('created_at >= ?', start).reorder(:id).to_a
    expect(versions.map(&:item_type)).to eq(%w[DatedPost DatedLine])
    expect(versions.map(&:transaction_id).uniq.length).to eq(1)
    # As PaperTrail dates an update by the record's updated_at, which the
    # line took before its callback saved the post.
    versions.last.update_columns(created_at: versions.first.created_at - 0.002)
    cut = versions.first.created_at - 0.001

    opened = start - 1
    split = rows(post.reload, opened...cut) + rows(post, cut..)

    expect(split.sort_by(&:to_s)).to eq(rows(post, opened..).sort_by(&:to_s))
    expect(split).to contain_exactly([nil, 'edits'], %w[DatedLine body])
  end
end
