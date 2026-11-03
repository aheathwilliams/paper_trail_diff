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

  create_table :json_history_files, force: true do |table|
    table.string :title, null: false
    table.text :meta
    table.binary :blob
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

# A serialized value and a binary one, which JSON history gives back as other
# types.
class JsonHistoryFile < ActiveRecord::Base
  serialize :meta, coder: YAML, type: Hash
  has_paper_trail
end

class JsonColumnHistoryFile < ActiveRecord::Base
  self.table_name = 'json_history_files'
  serialize :meta, coder: YAML, type: Hash
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
    # Some PaperTrail, Ruby, and adapter combinations cannot write JSON history
    # at all -- PaperTrail 16 passes a keyword newer json gems removed, and the
    # SQL Server adapter hands its JSON encoder a type wrapper that refuses
    # `as_json`. There is no history to compare there, so say why and stop.
    before do
      model.transaction do
        model.create!(title: 'Probe', published_at: published_at)
        raise ActiveRecord::Rollback
      end
    rescue StandardError => e
      skip "PaperTrail cannot record JSON history here: #{e.class}: #{e.message}"
    end

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

  describe 'values JSON gives back as other types' do
    let(:meta) { { 'due' => Date.new(2026, 11, 3), 'state' => :draft } }

    before do
      JsonHistoryFile.delete_all
      model.transaction do
        model.create!(title: 'Probe', meta: meta, blob: 'bytes')
        raise ActiveRecord::Rollback
      end
    rescue StandardError => e
      skip "PaperTrail cannot record JSON history here: #{e.class}: #{e.message}"
    end

    # Each version, and the current row, as the gem reads them.
    def states(file)
      steps = PaperTrailDiff.timeline(file, from: :first, to: file)
      [changed_names(PaperTrailDiff.compare(file.versions.last, file)),
       steps.map { |step| changed_names(step.diff) },
       PaperTrailDiff.analyze(file, from: file.versions.last, to: file, activity: true,
                                    snapshots: true)]
    end

    def edited(model)
      file = model.create!(title: 'Draft', meta: meta, blob: 'bytes')
      file.update!(title: 'Review')
      file.update!(title: 'Published')
      file.reload
    end

    context 'with a json object column' do
      let(:model) { JsonColumnHistoryFile }

      it 'reads a serialized value as JSON writes it, on every side' do
        compared, steps, analysis = states(edited(model))

        expect(compared).to eq(['title'])
        expect(steps).to eq([[], ['title'], ['title']])
        snapshots = [analysis.from_snapshot, analysis.to_snapshot]
        expect(snapshots.map { |state| state.attributes['meta'] })
          .to eq([{ 'due' => '2026-11-03', 'state' => 'draft' }] * 2)
      end
    end

    context 'with the JSON serializer on a text column' do
      let(:model) { JsonHistoryFile }

      around do |example|
        original = PaperTrail.serializer
        PaperTrail.serializer = PaperTrail::Serializers::JSON
        example.run
      ensure
        PaperTrail.serializer = original
      end

      it 'reads a binary value as its bytes' do
        compared, steps, analysis = states(edited(model))

        expect(compared).to eq(['title'])
        expect(steps).to eq([[], ['title'], ['title']])
        snapshots = [analysis.from_snapshot, analysis.to_snapshot]
        expect(snapshots.map { |state| state.attributes['blob'] }).to eq(['bytes'.b] * 2)
        expect(analysis.from_snapshot.attributes['meta']).to eq(meta)
      end
    end
  end

  it 'keeps full time precision for YAML history' do
    article = JsonHistoryArticle.create!(title: 'Draft', published_at: published_at)
    article.update!(published_at: published_at + Rational(1, 1_000_000))

    expect(changed_names(PaperTrailDiff.compare(article.versions.last, article)))
      .to eq(['published_at'])
  end
end
