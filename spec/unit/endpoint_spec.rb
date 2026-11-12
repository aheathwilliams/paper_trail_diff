# frozen_string_literal: true

require_relative '../support/filter_database'

RSpec.describe PaperTrailDiff::Endpoint do
  # A record of a versioned model without Active Record, which cannot say
  # whether it has unsaved changes.
  let(:plain_record) do
    Struct.new(:id, :destroyed?) do
      def persisted? = true
      def self.base_class = self
      def self.paper_trail_options = {}
      def self.paper_trail = Struct.new(:version_class).new(FilterVersion)
    end
  end

  before do
    FilterVersion.delete_all
    FilterArticle.unscoped.delete_all
  end

  # A record and its versions, created and then updated.
  def history(model = FilterArticle)
    record = model.create!(title: 'Draft')
    record.update!(title: 'Final')
    [record, *FilterVersion.where(item_id: record.id).order(:id).to_a]
  end

  def refused(message)
    raise_error(PaperTrailDiff::InvalidEndpointError, message)
  end

  describe '.validate_pair!' do
    it "accepts two versions of one item in order, or a version and the item's record" do
      feature, created, updated = history(FilterFeature)

      expect([[created, updated], [created, feature], [feature, created]].map do |from, to|
        described_class.validate_pair!(from, to)
      end).to eq([nil, nil, nil])
    end

    it 'refuses endpoints of two items' do
      _article, created, = history
      _other, other_created, = history

      expect { described_class.validate_pair!(created, other_created) }
        .to raise_error(PaperTrailDiff::VersionMismatchError,
                        'endpoints must belong to the same PaperTrail item')
    end

    it 'refuses versions newest first' do
      _article, created, updated = history

      expect { described_class.validate_pair!(updated, created) }
        .to raise_error(PaperTrailDiff::ReversedEndpointsError,
                        'version endpoints must be given in chronological order; swap them ' \
                        'to read the same difference in the other direction')
    end

    it 'checks each endpoint before comparing them' do
      _article, created, = history
      unsaved = FilterArticle.new(title: 'New')

      [[unsaved, created], [created, unsaved]].each do |from, to|
        expect { described_class.validate_pair!(from, to) }
          .to refused('current record endpoint must be persisted and not destroyed')
      end
    end
  end

  describe '.validate_order!' do
    it 'refuses only two versions newest first' do
      article, created, updated = history
      newer = FilterArticle.create!(title: 'Newer')

      expect { described_class.validate_order!(updated, created) }
        .to raise_error(PaperTrailDiff::ReversedEndpointsError, /\Aversion endpoints must be given/)
      expect([[created, updated], [created, created], [newer, created], [updated, article]]
        .map { |from, to| described_class.validate_order!(from, to) }).to eq([nil] * 4)
    end
  end

  describe '.validate!' do
    it 'accepts a version, and a saved record without unsaved changes' do
      article, created, = history

      expect([created, article, plain_record.new(1, false)]
        .map { |endpoint| described_class.validate!(endpoint) }).to eq([nil, nil, nil])
    end

    it 'refuses a record that is unsaved, destroyed or changed, and anything else' do
      article, = history
      destroyed, = history
      destroyed.destroy!
      article.title = 'Unsaved'

      [FilterArticle.new, destroyed, plain_record.new(1, true)].each do |record|
        expect { described_class.validate!(record) }
          .to refused('current record endpoint must be persisted and not destroyed')
      end
      expect { described_class.validate!(article) }
        .to refused('current record endpoint must not have unsaved changes')
      [nil, :first].each do |value|
        expect { described_class.validate!(value) }
          .to refused('expected a PaperTrail version or persisted record endpoint')
      end
    end
  end

  describe '.validate_root!' do
    it 'accepts a record of a versioned model, saved or destroyed, asking its class' do
      article, = history
      destroyed, = history
      destroyed.destroy!

      expect([article, destroyed, plain_record.new(1, false)]
        .map { |record| described_class.validate_root!(record) }).to eq([nil, nil, nil])
    end

    it 'names what it was given instead of a record, without loading a relation' do
      _article, created, = history
      relation = FilterArticle.all
      unnamed = Class.new
      given = [[nil, 'nil'], [FilterArticle, 'the class FilterArticle'],
               [created, 'FilterVersion'], [relation, relation.class.name],
               [unnamed.new, unnamed.to_s]]

      given.each do |value, named|
        expect { described_class.validate_root!(value) }
          .to refused("expected a record, got #{named}")
      end
      expect(relation).not_to be_loaded
    end

    it 'refuses a record of a model without history' do
      model = stub_const('UnversionedArticle',
                         Class.new(ActiveRecord::Base) { self.table_name = 'filter_articles' })

      expect { described_class.validate_root!(model.new) }
        .to refused('UnversionedArticle is not versioned, so it has no history: ' \
                    'add has_paper_trail to it')
    end
  end

  describe '.version? and .record?' do
    it 'tell a version from a record, and both from anything else' do
      article, created, = history
      values = [created, article, nil, :first, 'a title', FilterArticle]

      expect(values.map { |value| described_class.version?(value) })
        .to eq([true, false, false, false, false, false])
      expect(values.map { |value| described_class.record?(value) })
        .to eq([false, true, false, false, false, false])
    end
  end

  describe '.identity' do
    it "names a version's item, and a record by its base class, in strings" do
      feature, created, = history(FilterFeature)
      version = Struct.new(:item_type, :item_id) { def reify = nil }.new(:FilterArticle, feature.id)

      expect([created, feature, version].map { |endpoint| described_class.identity(endpoint) })
        .to eq([['FilterArticle', feature.id.to_s]] * 3)
    end

    it 'refuses anything else' do
      [nil, :first].each do |value|
        expect { described_class.identity(value) }
          .to refused('expected a PaperTrail version or persisted record endpoint')
      end
    end
  end

  describe '.model_class' do
    let(:subtyped) { Struct.new(:item_type, :item_subtype) }

    it "resolves a version's item type, or its subtype where its class records one" do
      _feature, created, = history(FilterFeature)
      versions = [created, subtyped.new('FilterArticle', 'FilterFeature'),
                  subtyped.new('FilterArticle', nil), subtyped.new('FilterArticle', '')]

      expect(versions.map { |version| described_class.model_class(version) })
        .to eq([FilterArticle, FilterFeature, FilterArticle, FilterArticle])
    end

    # A version is asked whether it was read with the column, not its class.
    it 'reads the subtype only of a version read with it' do
      modelled = Struct.new(:item_type, :item_subtype, :columns) do
        def self.column_names = %w[item_type item_subtype]
        def has_attribute?(name) = columns.include?(name)
      end
      _feature, created, = history(FilterFeature)
      partial = FilterVersion.select(:id, :item_type).find(created.id)
      versions = [modelled.new('FilterArticle', 'FilterFeature', %i[item_type item_subtype]),
                  modelled.new('FilterArticle', 'FilterFeature', %i[item_type]), partial,
                  Struct.new(:item_type).new('FilterArticle')]

      expect(versions.map { |version| described_class.model_class(version) })
        .to eq([FilterFeature, FilterArticle, FilterArticle, FilterArticle])
    end

    it 'refuses a type that names no class, or no type' do
      expect { described_class.model_class(subtyped.new('RemovedModel', nil)) }
        .to refused('cannot resolve endpoint model: RemovedModel')
      expect { described_class.model_class(subtyped.new(nil, nil)) }
        .to refused('cannot resolve endpoint model: ')
      expect { described_class.model_class(subtyped.new('FilterArticle', 'RemovedFeature')) }
        .to refused('cannot resolve endpoint model: RemovedFeature') { |error|
          expect(error.cause).to be_a(NameError)
        }
    end
  end

  describe '.versions' do
    it 'reads every version of the record' do
      article, created, updated = history
      history

      expect(described_class.versions(article).order(:id).to_a).to eq([created, updated])
    end

    it 'refuses something without a version history' do
      expect { described_class.versions(Object.new) }
        .to raise_error(PaperTrailDiff::InvalidTimelineRangeError,
                        'record does not expose a PaperTrail version history')
    end
  end

  describe '.reload_record' do
    it 'reads the record again, even where the default scope hides it' do
      article, = history
      FilterArticle.unscoped.where(id: article.id).update_all(title: 'Changed', hidden: 1)

      reloaded = described_class.reload_record(article)

      expect([reloaded.id, reloaded.title, article.title]).to eq([article.id, 'Changed', 'Final'])
    end

    it 'refuses a record it cannot use, or no longer finds' do
      article, = history
      FilterArticle.unscoped.where(id: article.id).delete_all

      expect { described_class.reload_record(FilterArticle.new) }
        .to refused('current record endpoint must be persisted and not destroyed')
      expect { described_class.reload_record(article) }
        .to refused('current record endpoint could not be reloaded from the database') { |error|
          expect(error.cause).to be_a(ActiveRecord::RecordNotFound)
        }
    end
  end
end
