# frozen_string_literal: true

require_relative '../support/core_database'

ActiveRecord::Schema.define do
  create_table :json_column_versions, force: true do |table|
    table.string :item_type, null: false
    table.string :item_id, null: false
    table.string :event, null: false
    table.string :whodunnit
    table.json :object
    table.json :object_changes
    table.datetime :created_at
  end

  create_table :json_history_articles, force: true do |table|
    table.string :title, null: false
    table.datetime :published_at, precision: 6
    table.timestamps null: false, precision: 6
  end
end

class JsonColumnVersion < ActiveRecord::Base
  include PaperTrail::VersionConcern
end

# Times are stored in history at JSON's precision and live at the database's.
class JsonHistoryArticle < ActiveRecord::Base
  has_paper_trail
end

class JsonColumnHistoryArticle < ActiveRecord::Base
  self.table_name = 'json_history_articles'
  has_paper_trail versions: { class_name: 'JsonColumnVersion' }
end

RSpec.describe 'History stored as JSON' do
  # Sub-millisecond digits that JSON encoding drops and the live row keeps.
  let(:published_at) { Time.utc(2026, 1, 1, 12, 0, 0, Rational(123_456)) }

  before do
    PaperTrail::Version.delete_all
    JsonColumnVersion.delete_all
    JsonHistoryArticle.delete_all
  end

  def changed_names(diff)
    diff.attributes.keys
  end

  shared_examples 'a lossy time history' do
    it 'does not report timestamps the history could not represent' do
      article = model.create!(title: 'Draft', published_at: published_at)
      article.update!(title: 'Review')
      article.update!(title: 'Published')

      expect(changed_names(PaperTrailDiff.compare(article.versions.last, article)))
        .to eq(['title'])
      expect(PaperTrailDiff.timeline(article, from: :first, to: article)
        .map { |step| changed_names(step.diff) }).to eq([[], ['title'], ['title']])
      expect(PaperTrailDiff.activity_timeline(article, from: :first, to: article)
        .map { |step| changed_names(step.diff) }).to eq([[], ['title'], ['title']])

      report = PaperTrailDiff.report(model.all, since: Time.utc(2000), limit: 5)
      expect(report.analyses.size).to eq(1)
      expect(report.analyses.values.first.activity_timeline.map { |step| changed_names(step.diff) })
        .to eq([[], ['title'], ['title']])
    end

    it 'still reports a time change the history did record' do
      article = model.create!(title: 'Draft', published_at: published_at)
      article.update!(title: 'Review')
      article.update!(published_at: published_at + 1)

      diff = PaperTrailDiff.compare(article.versions.last, article)

      expect(changed_names(diff)).to eq(['published_at'])
      expect(diff.attributes.fetch('published_at').to.to_i).to eq((published_at + 1).to_i)
    end
  end

  context 'with the JSON serializer on a text column' do
    let(:model) { JsonHistoryArticle }

    around do |example|
      original = PaperTrail.serializer
      PaperTrail.serializer = PaperTrail::Serializers::JSON
      example.run
    ensure
      PaperTrail.serializer = original
    end

    it_behaves_like 'a lossy time history'
  end

  context 'with a json object column' do
    let(:model) { JsonColumnHistoryArticle }

    it_behaves_like 'a lossy time history'
  end

  it 'keeps full time precision for YAML history' do
    article = JsonHistoryArticle.create!(title: 'Draft', published_at: published_at)
    article.update!(published_at: published_at + Rational(1, 1_000_000))

    expect(changed_names(PaperTrailDiff.compare(article.versions.last, article)))
      .to eq(['published_at'])
  end
end
