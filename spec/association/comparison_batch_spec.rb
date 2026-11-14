# frozen_string_literal: true

require_relative '../support/association_database'

ActiveRecord::Schema.define do
  create_table :comparison_shapes, force: true do |table|
    table.string :type
    table.string :name
    table.timestamps null: false
  end
end

class ComparisonShape < ActiveRecord::Base
  has_paper_trail
end

class ComparisonCircle < ComparisonShape; end

RSpec.describe PaperTrailDiff::ComparisonBatch do
  before do
    PaperTrail::VersionAssociation.delete_all
    PaperTrail::Version.delete_all
    [TrackedComment, TrackedArticle, ComparisonShape].each(&:delete_all)
  end

  let(:prepared) { [] }
  let(:version_prepared) { [] }

  def batch(comparisons)
    described_class.new(
      comparisons,
      live_loader: ->(records) { records.to_h { |record| [identity(record), record] } },
      preparer: ->(_model, historical:) {},
      history_preparer: ->(records, versions) { prepared << [records, versions] },
      version_history_preparer: ->(records, versions) { version_prepared << [records, versions] },
      historical_snapshotter: ->(_version) {},
      live_normalizer: ->(_record) {}
    )
  end

  def identity(endpoint)
    PaperTrailDiff::Endpoint.identity(endpoint)
  end

  def versions_of(article)
    2.times { |index| article.update!(title: "Title #{index}") }
    article.versions.reorder(:created_at, :id).to_a
  end

  it 'prepares a root compared between versions from its identity alone' do
    article = TrackedArticle.create!(title: 'Article')
    first, *, last = versions_of(article)

    batch([{ from: first, to: last }]).call

    expect(prepared).to eq([])
    records, versions = version_prepared.fetch(0)
    expect(version_prepared.length).to eq(1)
    expect(records.map { |record| [record.class, record.id, record.persisted?] })
      .to eq([[TrackedArticle, article.id, false]])
    expect(versions).to eq([first, last])
  end

  it 'prepares each version-only root once, with all of its versions' do
    article = TrackedArticle.create!(title: 'Article')
    other = TrackedArticle.create!(title: 'Other')
    article_versions = versions_of(article)
    other_versions = versions_of(other)

    batch([{ from: article_versions[0], to: article_versions[1] },
           { from: other_versions[1], to: other_versions[1] }]).call

    records, versions = version_prepared.fetch(0)
    expect(version_prepared.length).to eq(1)
    expect(records.map(&:id)).to eq([article.id, other.id])
    expect(versions).to eq([article_versions[0], article_versions[1], other_versions[1]])
  end

  # Version `retyped` recorded the shape before it became a circle.
  it 'prepares a root whose class changed between its versions once, as the later class' do
    shape = ComparisonShape.create!(name: 'shape')
    shape.update!(type: 'ComparisonCircle')
    ComparisonShape.find(shape.id).update!(name: 'circle')
    retyped, renamed = shape.versions.reorder(:created_at, :id).last(2)

    batch([{ from: retyped, to: renamed }]).call

    expect(version_prepared.length).to eq(1)
    records, versions = version_prepared.fetch(0)
    expect(records.map { |record| [record.class, record.id] }).to eq([[ComparisonCircle, shape.id]])
    expect(versions).to eq([retyped, renamed])
  end

  it 'prepares the roots of each later class together' do
    shape = ComparisonShape.create!(name: 'shape')
    shape.update!(type: 'ComparisonCircle')
    ComparisonShape.find(shape.id).update!(name: 'circle')
    plain = ComparisonShape.create!(name: 'plain')
    2.times { |index| plain.update!(name: "plain #{index}") }
    retyped, renamed = shape.versions.reorder(:created_at, :id).last(2)
    first, last = plain.versions.reorder(:created_at, :id).last(2)

    batch([{ from: retyped, to: renamed }, { from: first, to: last }]).call

    expect(version_prepared.map { |records, versions| [records.map(&:class), versions] })
      .to eq([[[ComparisonCircle], [retyped, renamed]], [[ComparisonShape], [first, last]]])
  end

  it 'prepares a root with a live endpoint from that record' do
    article = TrackedArticle.create!(title: 'Article')
    first, = versions_of(article)
    other = TrackedArticle.create!(title: 'Other')
    other_first, other_last = versions_of(other)

    batch([{ from: first, to: article }, { from: other_first, to: other_last }]).call

    expect(prepared).to eq([[[article], [first]]])
    records, versions = version_prepared.fetch(0)
    expect(records.map(&:id)).to eq([other.id])
    expect(versions).to eq([other_first, other_last])
  end

  it 'prepares the roots of each class with a live endpoint together, apart from other classes' do
    article = TrackedArticle.create!(title: 'Article')
    first, = versions_of(article)
    shape = ComparisonShape.create!(name: 'shape')
    shape.update!(name: 'renamed')
    renamed = shape.versions.reorder(:created_at, :id).last

    other = TrackedArticle.create!(title: 'Other')
    other_first, = versions_of(other)

    batch([{ from: first, to: article }, { from: renamed, to: shape },
           { from: other_first, to: other }]).call

    expect(prepared).to eq([[[article, other], [first, other_first]], [[shape], [renamed]]])
  end

  it 'prepares no history for a pair of live records' do
    article = TrackedArticle.create!(title: 'Article')

    batch([{ from: article, to: article }]).call

    expect(prepared).to eq([])
    expect(version_prepared).to eq([])
  end

  describe 'through compare_many' do
    def identity_of(record)
      PaperTrailDiff::Endpoint.identity(record)
    end

    def titles(diff)
      diff.attributes.fetch('title').to_h.values_at(:from, :to)
    end

    def edited(title)
      article = TrackedArticle.create!(title: title)
      article.update!(title: "#{title} 2")
      article.update!(title: "#{title} 3")
      [article, *article.versions.reorder(:created_at, :id).to_a]
    end

    def sql_during(&block)
      statements = []
      callback = proc do |_name, _start, _finish, _id, payload|
        statements << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached]
      end
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &block)
      statements
    end

    it 'answers each pair under its root, comparing versions and live records' do
      first, _created, first_edit, second_edit = edited('One')
      second, _other_created, other_edit, = edited('Two')

      results = PaperTrailDiff.compare_many(
        [{ from: first_edit, to: second_edit }, { 'from' => other_edit, 'to' => second }]
      )

      expect(results.keys).to eq([identity_of(first), identity_of(second)])
      expect(titles(results.fetch(identity_of(first)))).to eq(['One', 'One 2'])
      expect(titles(results.fetch(identity_of(second)))).to eq(['Two', 'Two 3'])
      expect(results).to be_frozen
      expect(results.keys).to all(be_frozen)
      expect(results.keys.map(&:object_id)).not_to include(identity_of(first).object_id)
    end

    it 'compares a version with the live record' do
      article, _created, edit, = edited('One')

      forward = PaperTrailDiff.compare_many([{ from: edit, to: article }])
      expect(titles(forward.fetch(identity_of(article)))).to eq(['One', 'One 3'])
    end

    it 'reads each live record once, however many pairs name it' do
      article, _created, edit, = edited('One')
      other, = edited('Two')

      statements = sql_during do
        PaperTrailDiff.compare_many([{ from: edit, to: article }, { from: other, to: other }])
      end

      expect(statements.grep(/FROM #{Regexp.escape(TrackedArticle.quoted_table_name)}/).length)
        .to eq(1)
    end

    it 'resolves :first to the earliest version, on either side of the pair' do
      article, created, = edited('One')
      other, other_created, = edited('Two')

      results = PaperTrailDiff.compare_many(
        [{ from: :first, to: article }, { from: :first, to: other_created }]
      )

      expect(results.keys).to eq([identity_of(article), identity_of(other)])
      explicit = PaperTrailDiff.compare_many([{ from: created, to: article }])
      expect(results.fetch(identity_of(article)).to_h)
        .to eq(explicit.fetch(identity_of(article)).to_h)
      expect(results.fetch(identity_of(article))).not_to be_empty
      expect(results.fetch(identity_of(other))).to be_empty
    end

    it 'answers a root with no history with an empty diff, under the record named' do
      untracked = PaperTrail.request(enabled: false) { TrackedArticle.create!(title: 'Quiet') }
      article, = edited('One')

      results = PaperTrailDiff.compare_many(
        [{ from: :first, to: untracked }, { from: :first, to: article }]
      )

      expect(results.keys).to eq([identity_of(untracked), identity_of(article)])
      expect(results.fetch(identity_of(untracked))).to be_a(PaperTrailDiff::Diff).and be_empty
      expect(results.fetch(identity_of(article))).not_to be_empty
    end

    it 'takes only an array of hashes with exactly from and to, under either kind of key' do
      article, = edited('One')
      pair = { from: article, to: article }
      message = 'comparisons[1]: must contain exactly from: and to:'

      expect { PaperTrailDiff.compare_many(pair) }
        .to raise_error(PaperTrailDiff::ConfigurationError,
                        'comparisons: must be an array of from:/to: hashes')
      [[article, article], { from: article }, { from: article, to: article, via: article },
       { from: article, 'from' => article }, { to: article, via: article }].each do |entry|
        expect { PaperTrailDiff.compare_many([pair, entry]) }
          .to raise_error(PaperTrailDiff::ConfigurationError, message)
      end
      expect(PaperTrailDiff.compare_many([{ 'to' => article, 'from' => article }]).values)
        .to all(be_empty)
      indifferent = ActiveSupport::HashWithIndifferentAccess.new(from: article, to: article)
      expect(PaperTrailDiff.compare_many(Class.new(Array).new([indifferent])).values)
        .to all(be_empty)
    end

    it 'refuses two pairs for one root, whichever endpoints name it' do
      article, _created, edit, last = edited('One')
      message = 'comparisons: root identities must be unique'

      expect do
        PaperTrailDiff.compare_many([{ from: edit, to: last }, { from: :first, to: article }])
      end
        .to raise_error(PaperTrailDiff::ConfigurationError, message)
      untracked = PaperTrail.request(enabled: false) { TrackedArticle.create!(title: 'Quiet') }
      expect do
        PaperTrailDiff.compare_many([{ from: :first, to: untracked },
                                     { from: untracked, to: :first }])
      end.to raise_error(PaperTrailDiff::ConfigurationError, message)
    end

    it 'checks each pair that has no unresolved boundary, and no other' do
      _, _created, edit, last = edited('One')
      other, = edited('Two')
      untracked = PaperTrail.request(enabled: false) { TrackedArticle.create!(title: 'Quiet') }

      expect do
        PaperTrailDiff.compare_many([{ from: untracked, to: untracked }, { from: edit, to: other }])
      end.to raise_error(PaperTrailDiff::VersionMismatchError)
      expect { PaperTrailDiff.compare_many([{ from: last, to: edit }]) }
        .to raise_error(PaperTrailDiff::ReversedEndpointsError)
      expect(PaperTrailDiff.compare_many([{ from: untracked, to: :first }]).values).to all(be_empty)
    end
  end

  describe 'preparing endpoint classes' do
    let(:classes) { [] }

    def class_batch(comparisons)
      described_class.new(
        comparisons,
        live_loader: ->(records) { records.to_h { |record| [identity(record), record] } },
        preparer: ->(model, historical:) { classes << [model, historical] },
        history_preparer: ->(_records, _versions) {},
        version_history_preparer: ->(_records, _versions) {},
        historical_snapshotter: ->(_version) {},
        live_normalizer: ->(_record) {}
      )
    end

    it 'prepares each class once, as historical when any endpoint of it is a version' do
      article = TrackedArticle.create!(title: 'Article')
      first, = versions_of(article)
      shape = ComparisonShape.create!(name: 'shape')

      class_batch([{ from: shape, to: shape }, { from: first, to: article }]).call
      expect(classes).to eq([[ComparisonShape, false], [TrackedArticle, true]])

      other = TrackedArticle.create!(title: 'Other')
      classes.clear
      class_batch([{ from: other, to: other }, { from: first, to: article }]).call
      expect(classes).to eq([[TrackedArticle, true]])

      classes.clear
      class_batch([{ from: first, to: article }, { from: other, to: other }]).call
      expect(classes).to eq([[TrackedArticle, true]])
    end

    it 'prepares nothing for a pair whose boundary stayed unresolved' do
      untracked = PaperTrail.request(enabled: false) { TrackedArticle.create!(title: 'Quiet') }

      class_batch([{ from: :first, to: untracked }]).call
      expect(classes).to eq([])
    end

    it 'loads and normalizes each live record once, and no version' do
      article = TrackedArticle.create!(title: 'Article')
      first, = versions_of(article)
      other = TrackedArticle.create!(title: 'Other')
      shape = ComparisonShape.create!(name: 'shape')
      loaded = []
      loader = lambda do |records|
        loaded << records
        records.to_h { |record| [identity(record), record] }
      end
      normalized = []
      described_class.new(
        [{ from: first, to: article }, { from: other, to: TrackedArticle.find(other.id) },
         { from: shape, to: shape.becomes(ComparisonCircle) }],
        live_loader: loader, preparer: ->(_model, historical:) {},
        history_preparer: ->(_records, _versions) {},
        version_history_preparer: ->(_records, _versions) {},
        historical_snapshotter: ->(_version) {},
        live_normalizer: ->(record) { normalized << record }
      ).call

      expect(loaded.map { |records| records.map(&:object_id) })
        .to eq([[article, other, shape].map(&:object_id)])
      expect(normalized.map(&:object_id)).to eq([article, other, shape].map(&:object_id))
    end
  end
end
