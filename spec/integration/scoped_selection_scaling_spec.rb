# frozen_string_literal: true

require_relative '../support/core_database'

ActiveRecord::Schema.define do
  # PaperTrail's default shape: an integer item_id matching an integer key.
  create_table :integer_item_versions, force: true do |table|
    table.string :item_type, null: false
    table.bigint :item_id, null: false
    table.string :event, null: false
    table.string :whodunnit
    table.text :object
    table.text :object_changes
    table.datetime :created_at
  end

  create_table :scaled_articles, force: true do |table|
    table.string :title, null: false
    table.timestamps null: false
  end
end

class IntegerItemVersion < ActiveRecord::Base
  include PaperTrail::VersionConcern
end

class ScaledArticle < ActiveRecord::Base
  has_paper_trail versions: { class_name: 'IntegerItemVersion' }
end

RSpec.describe 'scoped root selection over a busy window' do
  # Comfortably more than one selection page, so a plucked candidate list
  # would show up as a statement naming every id.
  let(:busy) { 600 }
  let(:window_start) { Time.now.utc - 3600 }

  before do
    IntegerItemVersion.delete_all
    ScaledArticle.delete_all
    now = Time.now.utc
    ScaledArticle.insert_all!(Array.new(busy) do |index|
      { title: "Article #{index}", created_at: now, updated_at: now }
    end)
    IntegerItemVersion.insert_all!(ScaledArticle.pluck(:id).map do |id|
      { item_type: 'ScaledArticle', item_id: id, event: 'create', created_at: now - 60 }
    end)
  end

  # The longest value list any statement carried, whether inlined or bound.
  def widest_statement(&block)
    widths = [0]
    callback = lambda do |*args|
      payload = args.last
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])

      widths << [payload[:sql].count(','), Array(payload[:binds]).length].max
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
    widths.max
  end

  it 'keeps the window activity out of the statements for a narrow relation' do
    target = ScaledArticle.order(:id).first
    report = nil

    width = widest_statement do
      report = PaperTrailDiff.report(ScaledArticle.where(id: target.id),
                                     since: window_start, limit: 1)
    end

    expect(report.analyses.keys).to eq([['ScaledArticle', target.id.to_s]])
    expect(width).to be < 20
  end

  it 'names deleted roots without listing the live ones' do
    removed = ScaledArticle.order(:id).last(2)
    ScaledArticle.where(id: removed.map(&:id)).delete_all

    report = PaperTrailDiff.report(ScaledArticle.where(id: 0), since: window_start, limit: 1)

    expect(report.analyses).to be_empty
    expect(report.unreachable).to eq(removed.map { |article| ['ScaledArticle', article.id.to_s] })
  end

  it 'still enforces the root ceiling' do
    expect { PaperTrailDiff.report(ScaledArticle, since: window_start, limit: busy - 1) }
      .to raise_error(PaperTrailDiff::BatchLimitExceededError)
  end
end
