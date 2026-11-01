# frozen_string_literal: true

require_relative '../support/filter_database'
require_relative '../support/normalizer_database'

RSpec.describe PaperTrailDiff::VersionRange do
  let(:start_time) { Time.utc(2032, 1, 1, 12) }

  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  # A create and three updates, a minute apart.
  def history(model = FilterArticle)
    article = model.create!(title: 'Draft')
    %w[Review Edited Published].each { |title| article.update!(title: title) }
    versions = article.versions.reorder(:id).to_a
    versions.each_with_index do |version, index|
      version.update_columns(created_at: start_time + (index * 60))
    end
    [article, *versions]
  end

  # The same history with ids running backwards, as a clock step or an
  # import leaves them: the newest version has the lowest id, so neither the
  # table's own order nor the ids give the order of time.
  def backwards_history
    article, *versions = history
    top = versions.map(&:id).max + versions.length
    versions.each_with_index { |version, index| version.update_columns(id: top - index) }
    [article, *versions]
  end

  def range(article, from, to, version_scope: nil)
    described_class.new(article, from: from, to: to, version_scope: version_scope)
  end

  def invalid(message)
    raise_error(PaperTrailDiff::InvalidTimelineRangeError, message)
  end

  describe '#select_plan_for_range' do
    it 'selects the versions from one boundary through the other, oldest first' do
      article, _created, reviewed, edited, published = backwards_history

      plan = range(article, reviewed, published).select_plan_for_range

      expect(plan.versions).to eq([reviewed, edited, published])
      expect(plan.steps).to eq([[reviewed, edited], [edited, published]])
    end

    it 'orders versions sharing a boundary timestamp by id' do
      article, created, reviewed, edited, published = history
      created.update_columns(created_at: reviewed.created_at)
      published.update_columns(created_at: edited.created_at)

      expect(range(article, reviewed, edited).select_plan_for_range.versions)
        .to eq([reviewed, edited])
    end

    it 'applies the version scope to the range alone' do
      article, _created, reviewed, edited, = history
      earliest = ->(versions) { versions.reorder(:created_at).limit(1) }
      latest = ->(versions) { versions.reorder(created_at: :desc).limit(1) }

      scoped = lambda do |scope|
        range(article, reviewed, edited, version_scope: scope).select_plan_for_range
      end

      expect(scoped.call(earliest).mutations).to eq([reviewed])
      expect(scoped.call(latest).mutations).to eq([edited])
    end

    it 'keeps a single version as both boundaries' do
      article, _created, reviewed, = history

      plan = range(article, reviewed, reviewed).select_plan_for_range

      expect(plan.versions).to eq([reviewed])
      expect(plan.steps).to eq([])
    end

    it 'bounds each selected version by the one after it, not by the next selected' do
      article, created, reviewed, edited, published = history
      skip_edit = ->(versions) { versions.where.not(id: edited.id) }

      plan = range(article, created, published, version_scope: skip_edit).select_plan_for_range

      expect(plan.mutations).to eq([created, reviewed, published])
      expect(plan.steps).to eq([[created, reviewed], [reviewed, edited]])
    end

    it 'rejects a from version that follows the to version' do
      article, _created, reviewed, edited, = history

      expect { range(article, edited, reviewed).validated_relation }
        .to invalid('`from` version must not follow `to` version')
    end

    it 'names the boundary that is not one of the record versions' do
      article, created, = history
      other, other_created, = history

      expect { range(article, other_created, created).validated_relation }
        .to invalid('`from` version is not in the record history')
      expect { range(article, created, other_created).validated_relation }
        .to invalid('`to` version is not in the record history')
      expect { range(article, created, other).validated_relation }
        .to invalid('`to` version is not in the record history')
      expect { range(article, nil, created).validated_relation }
        .to invalid('`from` version is not in the record history')
    end

    it 'rejects a version that is not stored in this history' do
      article, created, = history
      unsaved = FilterVersion.new(item_type: 'FilterArticle', item_id: article.id, event: 'update')
      foreign = NormVersion.new(item_type: 'FilterArticle', item_id: article.id, event: 'update',
                                id: created.id)

      expect { range(article, created, unsaved).validated_relation }
        .to invalid('`to` version is not in the record history')
      expect { range(article, created, foreign).validated_relation }
        .to invalid('`to` version is not in the record history')
    end

    it 'accepts the versions of a subclass record, stored under its base class' do
      feature, created, reviewed, = history(FilterFeature)

      expect(range(feature, created, reviewed).select_plan_for_range.versions)
        .to eq([created, reviewed])
    end
  end

  describe '#select_plan_through_current' do
    it 'selects from the boundary through the last version, then closes on the record' do
      article, created, reviewed, edited, published = history
      reviewed.update_columns(created_at: created.created_at)

      plan = range(article, reviewed, reviewed).select_plan_through_current(article)

      expect(plan.versions).to eq([reviewed, edited, published])
      expect(plan.closing_record).to equal(article)
    end

    it 'orders by time when the ids run the other way' do
      article, _created, reviewed, edited, published = backwards_history

      plan = range(article, reviewed, reviewed).select_plan_through_current(article)

      expect(plan.versions).to eq([reviewed, edited, published])
    end

    it 'applies the version scope from the boundary on' do
      article, _created, _reviewed, edited, = history
      earliest = ->(versions) { versions.reorder(:created_at).limit(1) }

      plan = range(article, edited, edited, version_scope: earliest)
             .select_plan_through_current(article)

      expect(plan.mutations).to eq([edited])
    end

    it 'rejects a current record other than the one whose history it reads' do
      article, created, = history
      other, = history

      expect { range(article, created, created).select_plan_through_current(other) }
        .to raise_error(PaperTrailDiff::VersionMismatchError)
    end

    it 'names a from boundary that is not one of the record versions' do
      article, = history
      _other, other_created, = history

      expect { range(article, other_created, other_created).select_plan_through_current(article) }
        .to invalid('`from` version is not in the record history')
    end
  end
end
